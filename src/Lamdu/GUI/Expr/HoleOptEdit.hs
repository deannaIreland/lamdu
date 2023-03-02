module Lamdu.GUI.Expr.HoleOptEdit
    ( make
    ) where

import qualified Control.Lens as Lens
import           Hyper
import           GUI.Momentu (Responsive)
import qualified GUI.Momentu as M
import qualified GUI.Momentu.Responsive as Responsive
import qualified GUI.Momentu.Responsive.Options as Options
import qualified Lamdu.Config.Theme.TextColors as TextColors
import           Lamdu.GUI.Styled (grammar, label)
import           Lamdu.GUI.Wrap (stdWrapParentExpr)
import qualified Lamdu.I18N.Code as Texts
import qualified Lamdu.GUI.Expr.GetVarEdit as GetVarEdit
import           Lamdu.GUI.Monad (GuiM)
import qualified Lamdu.GUI.Monad as GuiM
import qualified Lamdu.GUI.Types as ExprGui
import qualified Lamdu.GUI.WidgetIds as WidgetIds
import qualified Lamdu.Sugar.Types as Sugar

import           Lamdu.Prelude

make ::
    _ => ExprGui.Expr Sugar.HoleOpt i o -> GuiM env i o (Responsive o)
make (Ann (Const pl) b) =
    case b of
    Sugar.HoleBinder x -> GuiM.makeBinder (Ann (Const pl) x)
    Sugar.HoleVarsRecord fieldNames ->
        sequenceA
        [ grammar (label Texts.recordOpener) <&> Responsive.fromTextView
        , fieldNames
            & Lens.itraverse
            (\i fieldName ->
                let paramId = "params" <> M.asElemId i
                in
                myId <> paramId
                & GetVarEdit.makeSimpleView TextColors.variableColor fieldName
                <&> Responsive.fromWithTextPos
                & local (M.elemIdPrefix %~ (<> paramId))
            )
            >>= Options.boxSpaced Options.disambiguationNone
        , grammar (label Texts.recordCloser) <&> Responsive.fromTextView
        ] >>= Options.box Options.disambiguationNone
        & stdWrapParentExpr pl
        & local (M.elemIdPrefix .~ M.asElemId myId)
    where
        myId = WidgetIds.fromExprPayload pl
