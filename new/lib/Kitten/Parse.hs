{-# LANGUAGE OverloadedStrings #-}

module Kitten.Parse
  ( parse
  ) where

import Control.Applicative
import Control.Monad (guard, void)
import Data.List (find, findIndex, foldl')
import Data.Maybe (fromMaybe, isJust)
import Data.Text (Text)
import Kitten.DataConstructor (DataConstructor(DataConstructor))
import Kitten.Declaration (Declaration(Declaration))
import Kitten.Definition (Definition(Definition))
import Kitten.Element (Element)
import Kitten.Entry.Category (Category)
import Kitten.Entry.Parameter (Parameter(Parameter))
import Kitten.Fragment (Fragment(Fragment))
import Kitten.Informer (Informer(..))
import Kitten.Kind (Kind(..))
import Kitten.Located (Located)
import Kitten.Metadata (Metadata(Metadata))
import Kitten.Monad (K)
import Kitten.Name (GeneralName(..), Qualified(..), Qualifier(..), Unqualified(..))
import Kitten.Origin (Origin)
import Kitten.Parser (Parser, getOrigin)
import Kitten.Parser (parserMatch, parserMatch_)
import Kitten.Signature (Signature)
import Kitten.Synonym (Synonym(Synonym))
import Kitten.Term (Case(..), Else(..), Term(..), Value(..), compose)
import Kitten.Token (Token)
import Kitten.TypeDefinition (TypeDefinition(TypeDefinition))
import Text.Parsec ((<?>))
import Text.Parsec.Pos (SourcePos)
import qualified Data.HashMap.Strict as HashMap
import qualified Data.Text as Text
import qualified Kitten.DataConstructor as DataConstructor
import qualified Kitten.Declaration as Declaration
import qualified Kitten.Definition as Definition
import qualified Kitten.Element as Element
import qualified Kitten.Entry.Category as Category
import qualified Kitten.Entry.Merge as Merge
import qualified Kitten.Fragment as Fragment
import qualified Kitten.Layoutness as Layoutness
import qualified Kitten.Located as Located
import qualified Kitten.Metadata as Metadata
import qualified Kitten.Operator as Operator
import qualified Kitten.Origin as Origin
import qualified Kitten.Report as Report
import qualified Kitten.Signature as Signature
import qualified Kitten.Term as Term
import qualified Kitten.Token as Token
import qualified Kitten.TypeDefinition as TypeDefinition
import qualified Kitten.Vocabulary as Vocabulary
import qualified Text.Parsec as Parsec

parse :: FilePath -> [Located Token] -> K (Fragment ())
parse name tokens = let
  parsed = Parsec.runParser fragmentParser Vocabulary.global name tokens
  in case parsed of
    Left parseError -> do
      report $ Report.parseError parseError
      halt
    Right result -> return
      $ case find isMainDefinition $ Fragment.definitions result of
        Just{} -> result
        Nothing -> result
          { Fragment.definitions = mainDefinition
            (Identity () (Origin.point "<implicit>" 1 1))
            : Fragment.definitions result
          }

fragmentParser :: Parser (Fragment ())
fragmentParser = partitionElements <$> elementsParser <* Parsec.eof

elementsParser :: Parser [Element ()]
elementsParser = concat <$> many (vocabularyParser <|> (:[]) <$> elementParser)

partitionElements :: [Element ()] -> Fragment ()
partitionElements = rev . foldr go mempty
  where

  rev :: Fragment () -> Fragment ()
  rev fragment = Fragment
    { Fragment.declarations = reverse $ Fragment.declarations fragment
    , Fragment.definitions = reverse $ Fragment.definitions fragment
    , Fragment.metadata = reverse $ Fragment.metadata fragment
    , Fragment.synonyms = reverse $ Fragment.synonyms fragment
    , Fragment.types = reverse $ Fragment.types fragment
    }

  go :: Element () -> Fragment () -> Fragment ()
  go element acc = case element of
    Element.Declaration x -> acc
      { Fragment.declarations = x : Fragment.declarations acc }
    Element.Definition x -> acc
      { Fragment.definitions = x : Fragment.definitions acc }
    Element.Metadata x -> acc
      { Fragment.metadata = x : Fragment.metadata acc }
    Element.Synonym x -> acc
      { Fragment.synonyms = x : Fragment.synonyms acc }
    Element.TypeDefinition x -> acc
      { Fragment.types = x : Fragment.types acc }
    Element.Term x -> acc
      { Fragment.definitions
        = case findIndex isMainDefinition $ Fragment.definitions acc of
          Just index -> case splitAt index $ Fragment.definitions acc of
            (a, existing : b) -> a ++ existing { Definition.body
              = composeUnderLambda (Definition.body existing) x } : b
            _ -> error "cannot find main definition"
          Nothing -> mainDefinition x : Fragment.definitions acc
      }
      where

-- In top-level code, we want local variable bindings to remain in scope even
-- when separated by other top-level program elements, e.g.:
--
--     1 -> x;
--     define f (int -> int) { (+ 1) }
--     x say  // should work
--
-- As such, when composing top-level code, we extend the scope of lambdas to
-- include subsequent expressions.

      composeUnderLambda :: Term () -> Term () -> Term ()
      composeUnderLambda (Lambda type_ name varType body origin) term
        = Lambda type_ name varType (composeUnderLambda body term) origin
      composeUnderLambda a b = Compose () a b

mainDefinition :: Term a -> Definition a
mainDefinition body = Definition
  { Definition.body = body
  , Definition.category = Category.Word
  , Definition.fixity = Operator.Postfix
  , Definition.merge = Merge.Compose
  , Definition.name = Qualified Vocabulary.global "main"
  , Definition.origin = origin
  , Definition.signature = Signature.Quantified
    [Parameter origin "R" Stack, Parameter origin "S" Stack]
    (Signature.StackFunction "R" [] "S" []
      [QualifiedName (Qualified Vocabulary.global "IO")] origin) origin
  }
  where origin = Term.origin body

isMainDefinition :: Definition a -> Bool
isMainDefinition = (== Qualified Vocabulary.global "main") . Definition.name

vocabularyParser :: Parser [Element ()]
vocabularyParser = (<?> "vocabulary definition") $ do
  parserMatch_ Token.Vocab
  original@(Qualifier outer) <- Parsec.getState
  (vocabularyName, _) <- nameParser
  let
    (inner, name) = case vocabularyName of
      QualifiedName (Qualified (Qualifier qualifier) (Unqualified unqualified))
        -> (qualifier, unqualified)
      UnqualifiedName (Unqualified unqualified) -> ([], unqualified)
      LocalName{} -> error "local name should not appear as vocabulary name"
  Parsec.putState (Qualifier (outer ++ inner ++ [name]))
  Parsec.choice
    [ [] <$ parserMatchOperator ";"
    , do
      elements <- blockedParser elementsParser
      Parsec.putState original
      return elements
    ]

blockedParser :: Parser a -> Parser a
blockedParser = Parsec.between
  (parserMatch (Token.BlockBegin Layoutness.Nonlayout))
  (parserMatch Token.BlockEnd)

groupedParser :: Parser a -> Parser a
groupedParser = Parsec.between
  (parserMatch Token.GroupBegin) (parserMatch Token.GroupEnd)

groupParser :: Parser (Term ())
groupParser = do
  origin <- getOrigin
  groupedParser $ Group . compose () origin <$> Parsec.many1 termParser

-- See note [Angle Brackets].

angledParser :: Parser a -> Parser a
angledParser = Parsec.between
  (parserMatchOperator "<" <|> parserMatch Token.AngleBegin)
  (parserMatchOperator ">" <|> parserMatch Token.AngleEnd)

bracketedParser :: Parser a -> Parser a
bracketedParser = Parsec.between
  (parserMatch Token.VectorBegin) (parserMatch Token.VectorEnd)

nameParser :: Parser (GeneralName, Operator.Fixity)
nameParser = (<?> "name") $ do
  global <- isJust <$> Parsec.optionMaybe
    (parserMatch Token.Ignore <* parserMatch Token.VocabLookup)
  parts <- Parsec.choice
    [ (,) Operator.Postfix <$> wordNameParser
    , (,) Operator.Infix <$> operatorNameParser
    ] `Parsec.sepBy1` parserMatch Token.VocabLookup
  return $ case parts of
    [(fixity, unqualified)]
      -> ((if global
        then QualifiedName . Qualified Vocabulary.global
        else UnqualifiedName)
      unqualified, fixity)
    _ -> let
      parts' = map ((\ (Unqualified part) -> part) . snd) parts
      qualifier = init parts'
      (fixity, unqualified) = last parts
      in (QualifiedName (Qualified
        (Qualifier
          ((if global then (Vocabulary.globalName :) else id) qualifier))
        unqualified), fixity)

unqualifiedNameParser :: Parser Unqualified
unqualifiedNameParser = (<?> "unqualified name")
  $ wordNameParser <|> operatorNameParser

wordNameParser :: Parser Unqualified
wordNameParser = (<?> "word name") $ parseOne
  $ \ token -> case Located.item token of
    Token.Word name -> Just name
    _ -> Nothing

operatorNameParser :: Parser Unqualified
operatorNameParser = (<?> "operator name") $ do
  -- Rihtlice hi sind Angle gehatene, for ðan ðe hi engla wlite habbað.
  angles <- many $ parseOne $ \ token -> case Located.item token of
    Token.AngleBegin -> Just "<"
    Token.AngleEnd -> Just ">"
    _ -> Nothing
  rest <- parseOne $ \ token -> case Located.item token of
    Token.Operator (Unqualified name) -> Just name
    _ -> Nothing
  return $ Unqualified $ Text.concat $ angles ++ [rest]

parseOne :: (Located Token -> Maybe a) -> Parser a
parseOne = Parsec.tokenPrim show advance
  where
  advance :: SourcePos -> t -> [Located Token] -> SourcePos
  advance _ _ (token : _) = Origin.begin $ Located.origin token
  advance sourcePos _ _ = sourcePos

elementParser :: Parser (Element ())
elementParser = (<?> "top-level program element") $ Parsec.choice
  [ Element.Definition <$> Parsec.choice
    [ basicDefinitionParser
    , instanceParser
    , permissionParser
    ]
  , Element.Declaration <$> Parsec.choice
    [ traitParser
    , intrinsicParser
    ]
  , Element.Metadata <$> metadataParser
  , Element.Synonym <$> synonymParser
  , Element.TypeDefinition <$> typeDefinitionParser
  , do
    origin <- getOrigin
    Element.Term . compose () origin <$> Parsec.many1 termParser
  ]

synonymParser :: Parser Synonym
synonymParser = (<?> "synonym definition") $ do
  origin <- getOrigin <* parserMatch_ Token.Synonym
  from <- Qualified <$> Parsec.getState
    <*> unqualifiedNameParser
  (to, _) <- nameParser
  return $ Synonym from to origin

metadataParser :: Parser Metadata
metadataParser = (<?> "metadata block") $ do
  origin <- getOrigin <* parserMatch Token.About
  -- FIXME: This only allows metadata to be defined for elements within the
  -- current vocabulary.
  name <- Qualified <$> Parsec.getState
    <*> Parsec.choice
      [ unqualifiedNameParser <?> "word identifier"
      , (parserMatch Token.Type *> wordNameParser)
        <?> "'type' and type identifier"
      ]
  fields <- blockedParser $ many $ (,)
    <$> (wordNameParser <?> "metadata key identifier")
    <*> (blockParser <?> "metadata value block")
  return Metadata
    { Metadata.fields = HashMap.fromList fields
    , Metadata.name = QualifiedName name
    , Metadata.origin = origin
    }

typeDefinitionParser :: Parser TypeDefinition
typeDefinitionParser = (<?> "type definition") $ do
  origin <- getOrigin <* parserMatch Token.Type
  name <- Qualified <$> Parsec.getState
    <*> (wordNameParser <?> "type definition name")
  parameters <- Parsec.option [] quantifierParser
  constructors <- Parsec.choice
    [ blockedParser $ many constructorParser
{-
    -- FIXME: If types and words are in the same namespace, a constructor can't
    -- have the same name as its type, so this convenience syntax doesn't work.
    , do
      constructorOrigin <- getOrigin
      fields <- groupedParser $ constructorFieldsParser
      return $ (:[]) $ DataConstructor
        { DataConstructor.fields = fields
        , DataConstructor.name = unqualifiedName name
        , DataConstructor.origin = constructorOrigin
        }
-}
    ]
  return TypeDefinition
    { TypeDefinition.constructors = constructors
    , TypeDefinition.name = name
    , TypeDefinition.origin = origin
    , TypeDefinition.parameters = parameters
    }

constructorParser :: Parser DataConstructor
constructorParser = (<?> "constructor definition") $ do
  origin <- getOrigin <* parserMatch Token.Case
  name <- wordNameParser <?> "constructor name"
  fields <- (<?> "constructor fields") $ Parsec.option []
    $ groupedParser $ constructorFieldsParser
  return DataConstructor
    { DataConstructor.fields = fields
    , DataConstructor.name = name
    , DataConstructor.origin = origin
    }

constructorFieldsParser :: Parser [Signature]
constructorFieldsParser = typeParser `Parsec.sepEndBy` parserMatch Token.Comma

typeParser :: Parser Signature
typeParser = Parsec.try functionTypeParser <|> basicTypeParser <?> "type"

functionTypeParser :: Parser Signature
functionTypeParser = (<?> "function type") $ do
  (effect, origin) <- Parsec.choice
    [ do
      leftVar <- stack
      leftTypes <- Parsec.option [] (parserMatch Token.Comma *> left)
      origin <- arrow
      rightVar <- stack
      rightTypes <- Parsec.option [] (parserMatch Token.Comma *> right)
      return
        (Signature.StackFunction leftVar leftTypes rightVar rightTypes, origin)
    , do
      leftTypes <- left
      origin <- arrow
      rightTypes <- right
      return (Signature.Function leftTypes rightTypes, origin)
    ]
  permissions <- (<?> "permission labels")
    $ many $ parserMatchOperator "+" *> (fst <$> nameParser)
  return (effect permissions origin)
  where

  stack :: Parser Unqualified
  stack = Parsec.try $ wordNameParser <* parserMatch Token.Ellipsis

  left, right :: Parser [Signature]
  left = basicTypeParser `Parsec.sepEndBy` comma
  right = typeParser `Parsec.sepEndBy` comma

  comma :: Parser ()
  comma = void $ parserMatch Token.Comma

  arrow :: Parser Origin
  arrow = getOrigin <* parserMatch Token.Arrow

basicTypeParser :: Parser Signature
basicTypeParser = (<?> "basic type") $ do
  prefix <- Parsec.choice
    [ quantifiedParser $ groupedParser typeParser
    , Parsec.try $ do
      origin <- getOrigin
      (name, fixity) <- nameParser
      -- Must be a word, not an operator, but may be qualified.
      guard $ fixity == Operator.Postfix
      return $ Signature.Variable name origin
    , groupedParser typeParser
    ]
  let apply a b = Signature.Application a b $ Signature.origin prefix
  mSuffix <- Parsec.optionMaybe $ fmap concat
    $ Parsec.many1 $ typeListParser basicTypeParser
  return $ case mSuffix of
    Just suffix -> foldl' apply prefix suffix
    Nothing -> prefix

quantifierParser :: Parser [Parameter]
quantifierParser = typeListParser var
  where

  var :: Parser Parameter
  var = do
    origin <- getOrigin
    Parsec.choice
      [ (\ unqualified -> Parameter origin unqualified Permission)
        <$> (parserMatchOperator "+" *> wordNameParser)
      , do
        name <- wordNameParser
        (\ permission -> Parameter origin name permission)
          <$> Parsec.option Value (Stack <$ parserMatch Token.Ellipsis)
      ]

typeListParser :: Parser a -> Parser [a]
typeListParser element = angledParser
  $ element `Parsec.sepEndBy1` parserMatch Token.Comma

quantifiedParser :: Parser Signature -> Parser Signature
quantifiedParser thing = do
  origin <- getOrigin
  Signature.Quantified <$> quantifierParser <*> thing <*> pure origin

traitParser :: Parser Declaration
traitParser = (<?> "intrinsic declaration")
  $ declarationParser Token.Trait Declaration.Trait

intrinsicParser :: Parser Declaration
intrinsicParser = (<?> "intrinsic declaration")
  $ declarationParser Token.Intrinsic Declaration.Intrinsic

declarationParser :: Token -> Declaration.Category -> Parser Declaration
declarationParser keyword category = do
  origin <- getOrigin <* parserMatch keyword
  suffix <- unqualifiedNameParser <?> "declaration name"
  name <- Qualified <$> Parsec.getState <*> pure suffix
  signature <- signatureParser
  return Declaration
    { Declaration.category = category
    , Declaration.name = name
    , Declaration.origin = origin
    , Declaration.signature = signature
    }

basicDefinitionParser :: Parser (Definition ())
basicDefinitionParser = (<?> "word definition")
  $ definitionParser Token.Define Category.Word

instanceParser :: Parser (Definition ())
instanceParser = (<?> "instance definition")
  $ definitionParser Token.Instance Category.Instance

permissionParser :: Parser (Definition ())
permissionParser = (<?> "permission definition")
  $ definitionParser Token.Permission Category.Permission

definitionParser :: Token -> Category -> Parser (Definition ())
definitionParser keyword category = do
  origin <- getOrigin <* parserMatch keyword
  (fixity, suffix) <- Parsec.choice
    [ (,) Operator.Postfix <$> wordNameParser
    , (,) Operator.Infix <$> operatorNameParser
    ] <?> "definition name"
  name <- Qualified <$> Parsec.getState <*> pure suffix
  signature <- signatureParser
  body <- blockLikeParser <?> "definition body"
  return Definition
    { Definition.body = body
    , Definition.category = category
    , Definition.fixity = fixity
    , Definition.merge = Merge.Deny
    , Definition.name = name
    , Definition.origin = origin
    , Definition.signature = signature
    }

signatureParser :: Parser Signature
signatureParser = quantifiedParser signature <|> signature <?> "type signature"
  where signature = groupedParser functionTypeParser

blockParser :: Parser (Term ())
blockParser = blockedParser blockContentsParser <?> "block"

blockContentsParser :: Parser (Term ())
blockContentsParser = do
  origin <- getOrigin
  terms <- many termParser
  let origin' = case terms of { x : _ -> Term.origin x; _ -> origin }
  return $ foldr (Compose ()) (Identity () origin') terms

termParser :: Parser (Term ())
termParser = (<?> "expression") $ do
  origin <- getOrigin
  Parsec.choice
    [ Parsec.try (uncurry (Push ()) <$> parseOne toLiteral <?> "literal")
    , do
      (name, fixity) <- nameParser
      return (Word () fixity name [] origin)
    , Call () origin <$ parserMatch Token.Call
    , Parsec.try sectionParser
    , Parsec.try groupParser <?> "parenthesized expression"
    , vectorParser
    , lambdaParser
    , matchParser
    , ifParser
    , doParser
    , Push () <$> blockValue <*> pure origin
    , withParser
    ]
  where

  toLiteral :: Located Token -> Maybe (Value (), Origin)
  toLiteral token = case Located.item token of
    Token.Character x -> Just (Character x, origin)
    Token.Float a b c -> Just (Float $ Token.float a b c, origin)
    Token.Integer x _ -> Just (Integer x, origin)
    Token.Text x -> Just (Text x, origin)
    _ -> Nothing
    where

    origin :: Origin
    origin = Located.origin token

  sectionParser :: Parser (Term ())
  sectionParser = (<?> "operator section") $ groupedParser $ Parsec.choice
    [ do
      origin <- getOrigin
      function <- operatorNameParser
      let
        call = Word () Operator.Postfix
          (UnqualifiedName function) [] origin
      Parsec.choice
        [ do
          operandOrigin <- getOrigin
          operand <- Parsec.many1 termParser
          return $ compose () operandOrigin $ operand ++ [call]
        , return call
        ]
    , do
      operandOrigin <- getOrigin
      operand <- Parsec.many1
        $ Parsec.notFollowedBy operatorNameParser *> termParser
      origin <- getOrigin
      function <- operatorNameParser
      return $ compose () operandOrigin $ operand ++
        [ Swap () origin
        , Word () Operator.Postfix (UnqualifiedName function) [] origin
        ]
    ]

  vectorParser :: Parser (Term ())
  vectorParser = (<?> "vector literal") $ do
    vectorOrigin <- getOrigin
    elements <- bracketedParser
      $ termParser `Parsec.sepEndBy` parserMatch Token.Comma
    return $ compose () vectorOrigin $ elements
      ++ [NewVector () (length elements) vectorOrigin]

  lambdaParser :: Parser (Term ())
  lambdaParser = (<?> "variable introduction") $ Parsec.choice
    [ Parsec.try $ parserMatch Token.Arrow *> do
      names <- lambdaNamesParser <* parserMatchOperator ";"
      origin <- getOrigin
      body <- blockContentsParser
      return $ makeLambda names body origin
    , do
      body <- blockLambdaParser
      let origin = Term.origin body
      return $ Push () (Quotation body) origin
    ]

  matchParser :: Parser (Term ())
  matchParser = (<?> "match") $ do
    matchOrigin <- getOrigin <* parserMatch Token.Match
    scrutineeOrigin <- getOrigin
    mScrutinee <- Parsec.optionMaybe groupParser <?> "scrutinee"
    (cases, mElse) <- blockedParser $ do
      cases' <- many $ (<?> "case") $ parserMatch Token.Case *> do
        origin <- getOrigin
        (name, _) <- nameParser
        body <- blockLikeParser
        return $ Case name body origin
      mElse' <- Parsec.optionMaybe $ do
        origin <- getOrigin <* parserMatch Token.Else
        body <- blockParser
        return $ Else body origin
      return (cases', mElse')
    let match = Match () cases mElse matchOrigin
    return $ case mScrutinee of
      Just scrutinee -> compose () scrutineeOrigin [scrutinee, match]
      Nothing -> match

  ifParser :: Parser (Term ())
  ifParser = (<?> "if-else expression") $ do
    ifOrigin <- getOrigin <* parserMatch Token.If
    mCondition <- Parsec.optionMaybe groupParser <?> "condition"
    ifBody <- blockParser
    elifs <- many $ do
      origin <- getOrigin <* parserMatch Token.Elif
      condition <- groupParser <?> "condition"
      body <- blockParser
      return (condition, body, origin)
    else_ <- Parsec.option (Identity () ifOrigin)
      $ parserMatch Token.Else *> blockParser
    let
      desugarCondition (condition, body, origin) acc
        = compose () ifOrigin [condition, If () body acc origin]
    return $ foldr desugarCondition else_
      $ (fromMaybe (Identity () ifOrigin) mCondition, ifBody, ifOrigin)
      : elifs

  doParser :: Parser (Term ())
  doParser = (<?> "do expression") $ do
    doOrigin <- getOrigin <* parserMatch Token.Do
    term <- groupParser <?> "parenthesized expression"
    body <- blockLikeParser
    return $ compose () doOrigin
      [Push () (Quotation body) (Term.origin body), term]

  blockValue :: Parser (Value ())
  blockValue = (<?> "quotation") $ do
    origin <- getOrigin
    let
      reference = Word () Operator.Postfix
        <$> (parserMatch Token.Reference *> (fst <$> nameParser))
        <*> pure []
        <*> pure origin
    Quotation <$> (blockParser <|> reference)

  withParser :: Parser (Term ())
  withParser = (<?> "'with' expression") $ do
    origin <- getOrigin <* parserMatch_ Token.With
    permits <- groupedParser $ Parsec.many1 permitParser
    return $ With () permits origin
    where

    permitParser :: Parser Term.Permit
    permitParser = Term.Permit <$> Parsec.choice
      [ True <$ parserMatchOperator "+"
      , False <$ parserMatchOperator "-"
      ] <*> (UnqualifiedName <$> wordNameParser)

parserMatchOperator :: Text -> Parser (Located Token)
parserMatchOperator = parserMatch . Token.Operator . Unqualified

lambdaBlockParser :: Parser ([(Maybe Unqualified, Origin)], Term (), Origin)
lambdaBlockParser = parserMatch Token.Arrow *> do
  names <- lambdaNamesParser
  origin <- getOrigin
  body <- blockParser
  return (names, body, origin)

lambdaNamesParser :: Parser [(Maybe Unqualified, Origin)]
lambdaNamesParser = lambdaName `Parsec.sepEndBy1` parserMatch Token.Comma
  where
  lambdaName = do
    origin <- getOrigin
    name <- Just <$> wordNameParser <|> Nothing <$ parserMatch Token.Ignore
    return (name, origin)

blockLambdaParser :: Parser (Term ())
blockLambdaParser = do
  (names, body, origin) <- lambdaBlockParser
  return (makeLambda names body origin)

blockLikeParser :: Parser (Term ())
blockLikeParser = blockParser <|> blockLambdaParser

makeLambda :: [(Maybe Unqualified, Origin)] -> Term () -> Origin -> Term ()
makeLambda parsed body origin = foldr
  (\ (nameMaybe, nameOrigin) acc -> maybe
    (Compose () (Drop () origin) acc)
    (\ name -> Lambda () name () acc nameOrigin)
    nameMaybe)
  body
  (reverse parsed)
