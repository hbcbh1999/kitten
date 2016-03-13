{-# LANGUAGE OverloadedStrings #-}

module Kitten.Enter
  ( fragment
  , fragmentFromSource
  ) where

import Control.Monad ((>=>))
import Control.Monad.IO.Class (liftIO)
import Data.Foldable (foldlM)
import Data.Text (Text)
import Kitten.Definition (Definition)
import Kitten.Dictionary (Dictionary)
import Kitten.Fragment (Fragment)
import Kitten.Infer (typecheck)
import Kitten.Informer (checkpoint)
import Kitten.Layout (layout)
import Kitten.Monad (K)
import Kitten.Name (qualifierName)
import Kitten.Parse (parse)
import Kitten.Scope (scope)
import Kitten.Tokenize (tokenize)
import Kitten.TypeDefinition (TypeDefinition)
import Text.PrettyPrint.HughesPJClass (Pretty(..))
import qualified Data.HashMap.Strict as HashMap
import qualified Kitten.Definition as Definition
import qualified Kitten.Desugar.Data as Data
import qualified Kitten.Desugar.Infix as Infix
import qualified Kitten.Dictionary as Dictionary
import qualified Kitten.Entry as Entry
import qualified Kitten.Entry.Merge as Merge
import qualified Kitten.Fragment as Fragment
import qualified Kitten.Origin as Origin
import qualified Kitten.Pretty as Pretty
import qualified Kitten.Resolve as Resolve
import qualified Kitten.Term as Term
import qualified Kitten.TypeDefinition as TypeDefinition
import qualified Text.PrettyPrint as Pretty

fragment :: Fragment () -> Dictionary -> K Dictionary
fragment f
  = foldlMx declareTrait (Fragment.traits f)
  >=> foldlMx declareWord (Fragment.definitions f)
  >=> foldlMx declareType (Fragment.types f)
  >=> foldlMx resolveSignature (Fragment.definitions f)
  >=> foldlMx addMetadata (Fragment.metadata f)
  >=> foldlMx addOperatorMetadata (Fragment.operators f)
  >=> foldlMx defineWord (Fragment.definitions f)
  where
  foldlMx :: (Foldable f, Monad m) => (b -> a -> m b) -> f a -> b -> m b
  foldlMx = flip . foldlM

  declareTrait :: a
  declareTrait = error "declareTrait"

  addMetadata :: a
  addMetadata = error "addMetadata"

  addOperatorMetadata :: a
  addOperatorMetadata = error "addOperatorMetadata"

-- declare type, declare & define constructors
declareType :: Dictionary -> TypeDefinition -> K Dictionary
declareType dictionary type_ = let
  name = TypeDefinition.name type_
  in case HashMap.lookup name $ Dictionary.entries dictionary of
    -- Not previously declared.
    Nothing -> do
      let
        entry = Entry.Type
          (TypeDefinition.origin type_)
          (TypeDefinition.parameters type_)
      liftIO $ putStrLn $ Pretty.render $ Pretty.hsep ["Declaring type", Pretty.quote name]
      return dictionary
        { Dictionary.entries = HashMap.insert name entry
          $ Dictionary.entries dictionary }
    -- Previously declared with the same parameters.
    Just (Entry.Type _ parameters)
      | parameters == TypeDefinition.parameters type_
      -> do
        liftIO $ putStrLn $ Pretty.render $ Pretty.hsep ["Already declared type", Pretty.quote name]
        return dictionary
    -- Already declared or defined differently.
    Just{} -> error $ Pretty.render $ Pretty.hsep
      [ "type"
      , Pretty.quote name
      , "already declared or defined differently"
      ]

declareWord
  :: Dictionary -> Definition () -> K Dictionary
declareWord dictionary definition = let
  name = Definition.name definition
  signature = Definition.signature definition
  in case HashMap.lookup name $ Dictionary.entries dictionary of
    -- Not previously declared or defined.
    Nothing -> do
      let
        entry = Entry.Word
          (Definition.category definition)
          (Definition.merge definition)
          (Definition.origin definition)
          Nothing
          -- We don't attempt to resolve the signature because not all types
          -- have necessarily been declared yet.
          (Just signature)
          Nothing
        dictionary' = dictionary
          { Dictionary.entries = HashMap.insert name entry
            $ Dictionary.entries dictionary }
      liftIO $ putStrLn $ Pretty.render $ Pretty.hsep ["Declaring word", Pretty.quote name]
      return dictionary'
    -- Already declared with the same signature.
    Just (Entry.Word _ _ _ _ (Just signature') _)
      | signature' == signature
      -> do
        liftIO $ putStrLn $ Pretty.render $ Pretty.hsep ["Already declared word", Pretty.quote name]
        return dictionary
      | otherwise
      -> error $ Pretty.render $ Pretty.hsep
        [ "word"
        , Pretty.quote name
        , "already declared or defined with different signature:"
        , Pretty.text $ show signature
        , "vs"
        , Pretty.text $ show signature'
        ]
    -- Already declared or defined with a different signature.
    Just{} -> error $ Pretty.render $ Pretty.hsep
      [ "word"
      , Pretty.quote name
      , "already declared or defined without signature or as a non-word"
      ]

resolveSignature :: Dictionary -> Definition () -> K Dictionary
resolveSignature dictionary definition = do
  let name = Definition.name definition
  case HashMap.lookup name $ Dictionary.entries dictionary of
    Just (Entry.Word category merge origin parent (Just signature) body) -> do
      let qualifier = qualifierName name
      signature' <- Resolve.run $ Resolve.signature dictionary qualifier signature
      let
        entry = Entry.Word category merge origin parent (Just signature') body
      return dictionary
        { Dictionary.entries = HashMap.insert name entry
          $ Dictionary.entries dictionary }
    Nothing -> return dictionary  -- TODO: Error?

-- typecheck and define user-defined words
-- desugaring of operators has to take place here
defineWord
  :: Dictionary -> Definition () -> K Dictionary
defineWord dictionary definition = do
  let
    name = Definition.name definition
    signature = Definition.signature definition
  resolved <- Resolve.run $ Resolve.definition dictionary definition
  checkpoint
  let resolvedSignature = Definition.signature resolved
  -- Note that we use the resolved signature here.
  liftIO $ putStrLn $ Pretty.render $ Pretty.hsep ["Typechecking", Pretty.quote name, "with resolved signature", pPrint resolvedSignature]
  body' <- typecheck dictionary name resolvedSignature $ Definition.body resolved
  checkpoint
  liftIO $ putStrLn $ Pretty.render $ Pretty.hsep ["Typechecked", Pretty.quote name]
  case HashMap.lookup name $ Dictionary.entries dictionary of
    -- Previously declared with same signature, but not defined.
    Just (Entry.Word category merge origin' parent signature' Nothing)
      | maybe True (resolvedSignature ==) signature' -> do
      let entry = Entry.Word category merge origin' parent (Just resolvedSignature) (Just body')
      liftIO $ putStrLn $ Pretty.render $ Pretty.hsep ["Defining word", Pretty.quote name]
      return dictionary
        { Dictionary.entries = HashMap.insert name entry
          $ Dictionary.entries dictionary }
    -- Not previously declared.
    Nothing -> error $ Pretty.render $ Pretty.hsep
      [ "defining word"
      , Pretty.quote name
      , "not previously declared"
      ]
    -- Already defined as concatenable.
    Just (Entry.Word category merge@Merge.Compose
      origin' parent mSignature@(Just signature') body)
      | resolvedSignature == signature' -> do
      let
        body' = maybe (Term.Identity () (Origin.point "<implicit>" 1 1))
          Term.stripMetadata body
      -- Note that we use the resolved signature here.
      composed <- typecheck dictionary name resolvedSignature
        $ Term.Compose () body' (Definition.body definition)
      let
        entry = Entry.Word category merge origin' parent mSignature
          $ Just composed
      liftIO $ putStrLn $ Pretty.render $ Pretty.hsep ["Appending to word", Pretty.quote name]
      return dictionary
        { Dictionary.entries = HashMap.insert name entry
          $ Dictionary.entries dictionary }
    -- Already defined, not concatenable.
    redef@(Just (Entry.Word _ Merge.Deny _ _ (Just sig) _)) -> error $ Pretty.render $ Pretty.hcat
      [ "redefinition of existing word "
      , Pretty.quote name, " of signature ", pPrint sig
      , " with signature: "
      , pPrint resolvedSignature
      ]

fragmentFromSource :: FilePath -> Text -> K (Fragment ())
fragmentFromSource path source = do

-- Sources are lexed into a stream of tokens.

  tokenized <- tokenize path source
  checkpoint

-- Next, the layout rule is applied to desugar indentation-based syntax, so that
-- the parser can find the ends of blocks without checking the indentation of
-- tokens.

  laidout <- layout path tokenized
  checkpoint

-- We then parse the token stream as a series of top-level program elements.

  parsed <- parse path laidout
  checkpoint

-- Datatype definitions are desugared into regular definitions, so that name
-- resolution can find their names.

  Data.desugar parsed

resolveDefinition :: Dictionary -> Definition () -> K (Definition ())
resolveDefinition dictionary definition = do

-- Name resolution rewrites unqualified names into fully qualified names, so
-- that it's evident from a name which program element it refers to.

  -- needs dictionary for declared names
  resolved <- Resolve.run $ Resolve.definition dictionary definition
  checkpoint

-- After names have been resolved, the precedences of operators are known, so
-- infix operators can be desugared into postfix syntax.

  -- needs dictionary for operator metadata
  postfix <- Infix.desugar dictionary resolved
  checkpoint

-- In addition, now that we know which names refer to local variables,
-- quotations can be rewritten into closures that explicitly capture the
-- variables they use from the enclosing scope.

  return $ postfix { Definition.body = scope $ Definition.body postfix }
