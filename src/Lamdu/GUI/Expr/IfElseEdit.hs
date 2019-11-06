{-# LANGUAGE TemplateHaskell #-}
module Lamdu.GUI.Expr.IfElseEdit
    ( make
    ) where

import qualified Control.Lens as Lens
import qualified Control.Monad.Reader as Reader
import           Data.Functor.Compose (Compose(..))
import qualified Data.Map as Map
import           Data.Vector.Vector2 (Vector2(..))
import           GUI.Momentu.Align (WithTextPos)
import           GUI.Momentu.Animation (AnimId)
import qualified GUI.Momentu.Element as Element
import qualified GUI.Momentu.EventMap as E
import           GUI.Momentu.Glue ((/|/))
import qualified GUI.Momentu.Glue as Glue
import qualified GUI.Momentu.I18N as MomentuTexts
import           GUI.Momentu.Responsive (Responsive)
import qualified GUI.Momentu.Responsive as Responsive
import qualified GUI.Momentu.Responsive.Expression as ResponsiveExpr
import qualified GUI.Momentu.Responsive.Options as Options
import           GUI.Momentu.View (View)
import qualified GUI.Momentu.Widget as Widget
import qualified GUI.Momentu.Widgets.Grid as Grid
import qualified GUI.Momentu.Widgets.Spacer as Spacer
import           Hyper (Tree, Ann(..), hAnn)
import           Hyper.Combinator.Ann (Annotated)
import qualified Lamdu.Config as Config
import qualified Lamdu.GUI.Expr.EventMap as ExprEventMap
import           Lamdu.GUI.ExpressionGui.Monad (GuiM)
import qualified Lamdu.GUI.ExpressionGui.Monad as GuiM
import qualified Lamdu.GUI.ExpressionGui.Payload as ExprGui
import           Lamdu.GUI.ExpressionGui.Wrap (stdWrapParentExpr)
import           Lamdu.GUI.Styled (label, grammar)
import qualified Lamdu.GUI.WidgetIds as WidgetIds
import qualified Lamdu.I18N.Code as Texts
import qualified Lamdu.I18N.CodeUI as Texts
import qualified Lamdu.I18N.Definitions as Texts
import qualified Lamdu.I18N.Name as Texts
import qualified Lamdu.I18N.Navigation as Texts
import           Lamdu.Name (Name)
import qualified Lamdu.Sugar.Types as Sugar

import           Lamdu.Prelude

data Row a = Row
    { _rIndentId :: AnimId
    , _rKeyword :: a
    , _rPredicate :: a
    , _rResult :: a
    } deriving (Functor, Foldable, Traversable)
Lens.makeLenses ''Row

makeIfThen ::
    ( Monad i, Monad o
    , Has (Texts.Code Text) env
    , Has (MomentuTexts.Texts Text) env
    ) =>
    WithTextPos View -> AnimId ->
    Tree (Sugar.IfElse Name i o)
        (Ann (Const (Sugar.Payload Name i o ExprGui.Payload))) ->
    GuiM env i o (Row (Responsive o))
makeIfThen prefixLabel animId ifElse =
    do
        ifGui <-
            GuiM.makeSubexpression (ifElse ^. Sugar.iIf)
            /|/ (grammar (label Texts.injectSymbol) /|/ Spacer.stdHSpace)
        thenGui <- GuiM.makeSubexpression (ifElse ^. Sugar.iThen)
        keyword <-
            pure prefixLabel
            /|/ grammar (label Texts.if_)
            /|/ Spacer.stdHSpace
            <&> Responsive.fromTextView
        env <- Lens.view id
        let eventMap =
                foldMap
                (E.keysEventMapMovesCursor (Config.delKeys env)
                 ( E.toDoc env
                     [has . MomentuTexts.edit, has . MomentuTexts.delete]
                 ) . fmap WidgetIds.fromEntityId)
                (ifElse ^. Sugar.iElse . hAnn . Lens._Wrapped .
                 Sugar.plActions . Sugar.mReplaceParent)
        Row animId keyword
            (Widget.weakerEvents eventMap ifGui)
            (Widget.weakerEvents eventMap thenGui)
            & pure

makeElse ::
    ( Monad i, Monad o
    , Has (Texts.Code Text) env
    , Has (Texts.CodeUI Text) env
    , Has (MomentuTexts.Texts Text) env
    ) =>
    AnimId ->
    Annotated (Sugar.Payload Name i o ExprGui.Payload)
        (Sugar.Else Name i o) ->
    GuiM env i o [Row (Responsive o)]
makeElse parentAnimId (Ann (Const pl) (Sugar.SimpleElse expr)) =
    ( Row elseAnimId
        <$> (grammar (label Texts.else_) <&> Responsive.fromTextView)
        <*> (grammar (label Texts.injectSymbol)
                & Reader.local (Element.animIdPrefix .~ elseAnimId)
                <&> Responsive.fromTextView)
    ) <*> GuiM.makeSubexpression (Ann (Const pl) expr)
    <&> pure
    where
        elseAnimId = parentAnimId <> ["else"]
makeElse _ (Ann pl (Sugar.ElseIf (Sugar.ElseIfContent scopes content))) =
    do
        mOuterScopeId <- GuiM.readMScopeId
        let mInnerScope = lookupMKey <$> mOuterScopeId <*> scopes
        -- TODO: green evaluation backgrounds, "◗"?
        elseLabel <- grammar (label Texts.elseShort)
        letEventMap <-
            foldMap ExprEventMap.addLetEventMap (pl ^. Lens._Wrapped . Sugar.plActions . Sugar.mNewLet)
        (:)
            <$> ( makeIfThen elseLabel animId content
                  <&> Lens.mapped %~ Widget.weakerEvents letEventMap
                )
            <*> makeElse animId (content ^. Sugar.iElse)
            & Reader.local (Element.animIdPrefix .~ animId)
            & GuiM.withLocalMScopeId mInnerScope
    where
        animId = WidgetIds.fromEntityId entityId & Widget.toAnimId
        entityId = pl ^. Lens._Wrapped . Sugar.plEntityId
        -- TODO: cleaner way to write this?
        lookupMKey k m = k >>= (`Map.lookup` m)

verticalRowRender ::
    ( Monad o, MonadReader env f, Spacer.HasStdSpacing env
    , Has ResponsiveExpr.Style env, Glue.HasTexts env
    ) => f (Row (Responsive o) -> Responsive o)
verticalRowRender =
    do
        indent <- ResponsiveExpr.indent
        obox <- Options.box
        vbox <- Responsive.vboxSpaced
        pure $
            \row ->
            vbox
            [ obox Options.disambiguationNone [row ^. rKeyword, row ^. rPredicate]
            , indent (row ^. rIndentId) (row ^. rResult)
            ]

renderRows ::
    ( Monad o, MonadReader env f, Spacer.HasStdSpacing env
    , Has ResponsiveExpr.Style env
    , Grid.HasTexts env
    ) => Maybe AnimId -> f ([Row (Responsive o)] -> Responsive o)
renderRows mParensId =
    do
        vspace <- Spacer.getSpaceSize <&> (^._2)
        -- TODO: better way to make space between rows in grid??
        obox <- Options.box
        pad <- Element.pad
        let -- When there's only "if" and "else", we want to merge the predicate with the keyword
            -- because there are no several predicates to be aligned
            prep2 row =
                row
                & rKeyword .~ obox Options.disambiguationNone [row ^. rKeyword, row ^. rPredicate]
                & rPredicate .~ Element.empty
        let spaceAbove = (<&> pad (Vector2 0 vspace) 0)
        let prepareRows [] = []
            prepareRows [x, y] = [prep2 x, spaceAbove (prep2 y)]
            prepareRows (x:xs) = x : (xs <&> spaceAbove)
        vert <- verticalRowRender
        addParens <- maybe (pure id) (ResponsiveExpr.addParens ??) mParensId
        vbox <- Responsive.vboxSpaced
        table <- Options.table
        pure $
            \rows ->
            vbox (rows <&> vert)
            & Options.tryWideLayout table (Compose (prepareRows rows))
            & Responsive.rWideDisambig %~ addParens

make ::
    ( Monad i, Monad o
    , Grid.HasTexts env
    , Has (Texts.Code Text) env
    , Has (Texts.CodeUI Text) env
    , Has (Texts.Definitions Text) env
    , Has (Texts.Name Text) env
    , Has (Texts.Navigation Text) env
    ) =>
    Tree (Sugar.IfElse Name i o)
        (Ann (Const (Sugar.Payload Name i o ExprGui.Payload))) ->
    Sugar.Payload Name i o ExprGui.Payload ->
    GuiM env i o (Responsive o)
make ifElse pl =
    stdWrapParentExpr pl
    <*> ( renderRows (ExprGui.mParensId pl)
            <*>
            ( (:)
                <$> makeIfThen Element.empty animId ifElse
                <*> makeElse animId (ifElse ^. Sugar.iElse)
            )
        )
    where
        animId = WidgetIds.fromExprPayload pl & Widget.toAnimId
