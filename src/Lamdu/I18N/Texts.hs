{-# LANGUAGE TemplateHaskell, FlexibleInstances, DerivingVia, RankNTypes #-}
module Lamdu.I18N.Texts where

import qualified Control.Lens as Lens
import           Data.Aeson.TH (deriveJSON)
import qualified Data.Aeson.Types as Aeson
import           Data.List.Lens (prefixed)
import           Lamdu.Config.Folder (HasConfigFolder(..))

import           Lamdu.Prelude

data Code a = Code
    { _assign :: a -- Assignment
    , _relay :: a -- Apply
    , _let_ :: a
    , _toNom :: a
    , _fromNom :: a
    , _repl :: a
    , -- Case
      _case_ :: a
    , _of_ :: a
    , _absurd :: a
    , -- If:
      _if_ :: a
    , _condColon :: a -- Colon after if's condition
    , _else_ :: a
    , _elseShort :: a -- "el" in "elif"
    , -- Inject
      _inject :: a
    , _nullaryInject :: a
    , -- Getvar
      _paramsRecordOpener :: a
    , _paramsRecordCloser :: a
    , -- Lambda:
      _defer :: a
    , _lam :: a
    , _arrow :: a
    , -- Literal a:
      _textOpener :: a
    , _textCloser :: a
    , -- Record:
      _recordOpener :: a
    , _recordSep :: a
    , _recordCloser :: a
    }
    deriving stock (Generic, Generic1, Eq, Ord, Show, Functor, Foldable, Traversable)
    deriving Applicative via (Generically1 Code)
Lens.makeLenses ''Code
deriveJSON Aeson.defaultOptions {Aeson.fieldLabelModifier = (^?! prefixed "_")} ''Code

data CodeUI a = CodeUI
    { _newDefinitionButton :: a
    , _undeleteButton :: a
    , _defUpdateHeader :: a
    , _defUpdateTo :: a
    , _defUpdateWas :: a
    }
    deriving stock (Generic, Generic1, Eq, Ord, Show, Functor, Foldable, Traversable)
    deriving Applicative via (Generically1 CodeUI)
Lens.makeLenses ''CodeUI
deriveJSON Aeson.defaultOptions {Aeson.fieldLabelModifier = (^?! prefixed "_")} ''CodeUI

data StatusBar a = StatusBar
    { _annotations :: a
    , _branch :: a
    , _help :: a
    , _language :: a
    , _theme :: a
    }
    deriving stock (Generic, Generic1, Eq, Ord, Show, Functor, Foldable, Traversable)
    deriving Applicative via (Generically1 StatusBar)
Lens.makeLenses ''StatusBar
deriveJSON Aeson.defaultOptions {Aeson.fieldLabelModifier = (^?! prefixed "_")} ''StatusBar

data Texts a = Texts
    { -- TODO: Should this still be called "Texts?"
      -- Using a boolean for the JSON instance
      _isLeftToRight :: Bool
    , _code :: Code a
    , _codeUI :: CodeUI a
    , _statusBar :: StatusBar a
    }
    deriving stock (Eq, Ord, Show, Functor, Foldable, Traversable)
-- Get-field's dot is currently omitted from the symbols,
-- because it has special disambiguation logic implemented in the dotter etc.

Lens.makeLenses ''Texts
deriveJSON Aeson.defaultOptions {Aeson.fieldLabelModifier = (^?! prefixed "_")} ''Texts

type Language = Texts Text

instance HasConfigFolder Language where
    configFolder _ = "languages"

class HasTexts env where texts :: Lens' env Language
instance HasTexts (Texts Text) where texts = id

dummy :: Texts ()
dummy =
    Texts
    { _isLeftToRight = True
    , _code = pure ()
    , _codeUI = pure ()
    , _statusBar = pure ()
    }
