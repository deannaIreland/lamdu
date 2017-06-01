{-# LANGUAGE NoImplicitPrelude, TemplateHaskell, RankNTypes, DisambiguateRecordFields, NamedFieldPuns, OverloadedStrings #-}
module Lamdu.GUI.Main
    ( make
    , Env(..), CodeEdit.ExportActions(..)
      , envEvalRes, envExportActions
      , envConfig, envTheme, envSettings, envStyle, envFullSize, envCursor
    , CodeEdit.M(..), CodeEdit.m, defaultCursor
    ) where

import qualified Control.Lens as Lens
import           Data.CurAndPrev (CurAndPrev(..))
import           Data.Store.Transaction (Transaction)
import           Data.Vector.Vector2 (Vector2(..))
import qualified Graphics.UI.Bottle.EventMap as EventMap
import           Graphics.UI.Bottle.Widget (Widget)
import qualified Graphics.UI.Bottle.Widget as Widget
import qualified Graphics.UI.Bottle.Widgets.Box as Box
import           Lamdu.Config (Config)
import qualified Lamdu.Config as Config
import           Lamdu.Config.Theme (Theme)
import qualified Lamdu.Config.Theme as Theme
import qualified Lamdu.Data.DbLayout as DbLayout
import           Lamdu.Eval.Results (EvalResults)
import qualified Lamdu.Expr.IRef as ExprIRef
import qualified Lamdu.GUI.CodeEdit as CodeEdit
import           Lamdu.GUI.CodeEdit.Settings (Settings(..))
import qualified Lamdu.GUI.Scroll as Scroll
import qualified Lamdu.GUI.Spacing as Spacing
import qualified Lamdu.GUI.VersionControl as VersionControlGUI
import qualified Lamdu.GUI.WidgetIds as WidgetIds
import           Lamdu.GUI.WidgetsEnvT (runWidgetEnvT)
import qualified Lamdu.GUI.WidgetsEnvT as WE
import           Lamdu.Style (Style)
import qualified Lamdu.Style as Style
import qualified Lamdu.VersionControl as VersionControl
import qualified Lamdu.VersionControl.Actions as VersionControl.Actions

import           Lamdu.Prelude

type T = Transaction

data Env = Env
    { _envEvalRes :: CurAndPrev (EvalResults (ExprIRef.ValI DbLayout.ViewM))
    , _envExportActions :: CodeEdit.ExportActions DbLayout.ViewM
    , _envConfig :: Config
    , _envTheme :: Theme
    , _envSettings :: Settings
    , _envStyle :: Style
    , _envFullSize :: Widget.Size
    , _envCursor :: Widget.Id
    }
Lens.makeLenses ''Env

defaultCursor :: Widget.Id
defaultCursor = WidgetIds.replId

make :: Env -> T DbLayout.DbM (Widget (CodeEdit.M DbLayout.DbM Widget.EventResult))
make env =
    do
        actions <-
            VersionControl.makeActions
            <&> VersionControl.Actions.hoist CodeEdit.mLiftTrans
        runWidgetEnvT widgetEnv $
            do
                branchGui <-
                    VersionControlGUI.make (Config.versionControl config) (Theme.versionControl theme)
                    CodeEdit.mLiftTrans id actions $
                    \branchSelector ->
                    do
                        let codeSize = fullSize - Vector2 0 (branchSelector ^. Widget.height)
                        codeEdit <-
                            CodeEdit.make codeEditEnv ?? (codeSize ^. _1)
                            & WE.mapWidgetEnvT VersionControl.runAction
                            <&> Widget.events . CodeEdit.m %~ fmap (VersionControl.runEvent cursor)
                        topPadding <- Theme.topPadding theme & Spacing.vspacer
                        let scrollBox =
                                Box.vbox [(0.5, topPadding), (0.5, codeEdit)]
                                & Widget.padToSizeAlign codeSize 0
                                & Scroll.focusAreaIntoWindow fullSize
                                & Widget.size .~ codeSize
                        Box.vbox [(0.5, scrollBox), (0.5, branchSelector)]
                            & return
                let quitEventMap =
                        Widget.keysEventMap (Config.quitKeys config) (EventMap.Doc ["Quit"]) (error "Quit")
                branchGui
                    & Widget.strongerEvents quitEventMap
                    & return
    where
        Env evalResults exportActions config theme settings style fullSize cursor = env
        codeEditEnv = CodeEdit.Env
            { codeProps = DbLayout.codeProps
            , evalResults
            , config
            , theme
            , settings
            , style
            , exportActions
            }
        widgetEnv = WE.Env
            { WE._envCursor = cursor
            , WE._envTextStyle = Style.styleBase style
            , WE._stdSpacing = Theme.stdSpacing theme
            }
