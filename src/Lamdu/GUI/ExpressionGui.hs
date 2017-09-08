{-# LANGUAGE NoImplicitPrelude, RecordWildCards, OverloadedStrings, RankNTypes, TypeFamilies, LambdaCase, DeriveTraversable , FlexibleContexts #-}
module Lamdu.GUI.ExpressionGui
    ( ExpressionGui
    , render
    -- General:
    , listWithDelDests
    , grammarLabel
    , addValFrame, addValPadding
    , addValBGWithColor
    -- Lifted widgets:
    , makeNameView
    , makeBareNameEdit
    , makeNameEdit
    , makeNameOriginEdit, styleNameOrigin
    , addDeletionDiagonal
    -- Info adding
    , annotationSpacer
    , NeighborVals(..)
    , EvalAnnotationOptions(..), maybeAddAnnotationWith
    , WideAnnotationBehavior(..), wideAnnotationBehaviorFromSelected
    , evaluationResult
    -- Expression wrapping

    , Precedence.MyPrecedence(..)
    , Precedence.ParentPrecedence(..)
    , Precedence.Precedence(..)
    , Precedence.before, Precedence.after

    , maybeAddAnnotationPl
    , stdWrap
    , parentDelegator
    , stdWrapParentExpr
    ) where

import qualified Control.Lens as Lens
import qualified Control.Monad.Reader as Reader
import           Data.Binary.Utils (encodeS)
import           Data.CurAndPrev (CurAndPrev(..), CurPrevTag(..), curPrevTag, fallbackToPrev)
import qualified Data.List.Utils as ListUtils
import           Data.Store.Property (Property(..))
import           Data.Store.Transaction (Transaction)
import qualified Data.Text as Text
import           Data.Vector.Vector2 (Vector2(..))
import           GUI.Momentu.Align (Aligned(..), WithTextPos(..))
import qualified GUI.Momentu.Align as Align
import           GUI.Momentu.Animation (AnimId)
import qualified GUI.Momentu.Animation as Anim
import qualified GUI.Momentu.Draw as Draw
import           GUI.Momentu.Element (Element)
import qualified GUI.Momentu.Element as Element
import qualified GUI.Momentu.EventMap as E
import           GUI.Momentu.Glue ((/-/), (/|/))
import           GUI.Momentu.MetaKey (MetaKey(..), noMods)
import qualified GUI.Momentu.MetaKey as MetaKey
import           GUI.Momentu.Responsive (Responsive(..))
import qualified GUI.Momentu.Responsive as Responsive
import           GUI.Momentu.View (View)
import qualified GUI.Momentu.View as View
import           GUI.Momentu.Widget (Widget)
import qualified GUI.Momentu.Widget as Widget
import qualified GUI.Momentu.Widgets.FocusDelegator as FocusDelegator
import qualified GUI.Momentu.Widgets.Spacer as Spacer
import qualified GUI.Momentu.Widgets.TextEdit as TextEdit
import qualified GUI.Momentu.Widgets.TextEdit.Property as TextEdits
import qualified GUI.Momentu.Widgets.TextView as TextView
import           Lamdu.Calc.Type (Type)
import qualified Lamdu.Calc.Type as T
import           Lamdu.Config (Config)
import qualified Lamdu.Config as Config
import           Lamdu.Config.Theme (Theme, HasTheme(..))
import qualified Lamdu.Config.Theme as Theme
import qualified Lamdu.Eval.Results as ER
import qualified Lamdu.GUI.CodeEdit.Settings as CESettings
import qualified Lamdu.GUI.EvalView as EvalView
import qualified Lamdu.GUI.ExpressionEdit.EventMap as ExprEventMap
import           Lamdu.GUI.ExpressionGui.Monad (ExprGuiM)
import qualified Lamdu.GUI.ExpressionGui.Monad as ExprGuiM
import           Lamdu.GUI.ExpressionGui.Types (ExpressionGui, ShowAnnotation(..), EvalModeShow(..))
import qualified Lamdu.GUI.ExpressionGui.Types as ExprGuiT
import qualified Lamdu.GUI.Precedence as Precedence
import qualified Lamdu.GUI.TypeView as TypeView
import qualified Lamdu.GUI.WidgetIds as WidgetIds
import qualified Lamdu.Style as Style
import           Lamdu.Sugar.Names.Types (Name(..))
import qualified Lamdu.Sugar.Names.Types as Name
import qualified Lamdu.Sugar.Types as Sugar

import           Lamdu.Prelude

type T = Transaction

addAnnotationBackgroundH ::
    (MonadReader env m, Theme.HasTheme env, Element a) =>
    (Theme.ValAnnotation -> Draw.Color) -> AnimId -> m (a -> a)
addAnnotationBackgroundH getColor animId =
    Lens.view theme <&>
    \t ->
    Draw.backgroundColor bgAnimId (getColor (Theme.valAnnotation t))
    where
        bgAnimId = animId ++ ["annotation background"]

addAnnotationBackground :: (MonadReader env m, Theme.HasTheme env, Element a) => AnimId -> m (a -> a)
addAnnotationBackground = addAnnotationBackgroundH Theme.valAnnotationBGColor

addAnnotationHoverBackground :: (MonadReader env m, Theme.HasTheme env, Element a) => AnimId -> m (a -> a)
addAnnotationHoverBackground = addAnnotationBackgroundH Theme.valAnnotationHoverBGColor

data WideAnnotationBehavior
    = ShrinkWideAnnotation
    | HoverWideAnnotation
    | KeepWideAnnotation

wideAnnotationBehaviorFromSelected :: Bool -> WideAnnotationBehavior
wideAnnotationBehaviorFromSelected False = ShrinkWideAnnotation
wideAnnotationBehaviorFromSelected True = HoverWideAnnotation

-- NOTE: Also adds the background color, because it differs based on
-- whether we're hovering
applyWideAnnotationBehavior ::
    Monad m =>
    AnimId -> WideAnnotationBehavior ->
    ExprGuiM m (Vector2 Widget.R -> View -> View)
applyWideAnnotationBehavior animId KeepWideAnnotation =
    addAnnotationBackground animId <&> const
applyWideAnnotationBehavior animId ShrinkWideAnnotation =
    addAnnotationBackground animId
    <&>
    \addBg shrinkRatio layout ->
    Element.scale shrinkRatio layout & addBg
applyWideAnnotationBehavior animId HoverWideAnnotation =
    do
        shrinker <- applyWideAnnotationBehavior animId ShrinkWideAnnotation
        addBg <- addAnnotationHoverBackground animId
        return $
            \shrinkRatio layout ->
                addBg layout
                -- TODO: This is a buggy hover that ignores
                -- Surrounding (and exits screen).
                & (`View.hoverInPlaceOf` shrinker shrinkRatio layout)

processAnnotationGui ::
    Monad m =>
    AnimId -> WideAnnotationBehavior ->
    ExprGuiM m (Widget.R -> View -> View)
processAnnotationGui animId wideAnnotationBehavior =
    f
    <$> (Lens.view theme <&> Theme.valAnnotation)
    <*> addAnnotationBackground animId
    <*> Spacer.getSpaceSize
    <*> applyWideAnnotationBehavior animId wideAnnotationBehavior
    where
        f th addBg stdSpacing applyWide minWidth annotation
            | annotationWidth > minWidth + max shrinkAtLeast expansionLimit
            || heightShrinkRatio < 1 =
                applyWide shrinkRatio annotation
            | otherwise =
                maybeTooNarrow annotation & addBg
            where
                annotationWidth = annotation ^. Element.width
                expansionLimit =
                    Theme.valAnnotationWidthExpansionLimit th & realToFrac
                maxWidth = minWidth + expansionLimit
                shrinkAtLeast = Theme.valAnnotationShrinkAtLeast th & realToFrac
                heightShrinkRatio =
                    Theme.valAnnotationMaxHeight th * stdSpacing ^. _2
                    / annotation ^. Element.height
                shrinkRatio =
                    annotationWidth - shrinkAtLeast & min maxWidth & max minWidth
                    & (/ annotationWidth) & min heightShrinkRatio & pure
                maybeTooNarrow
                    | minWidth > annotationWidth = Element.pad (Vector2 ((minWidth - annotationWidth) / 2) 0)
                    | otherwise = id

data EvalResDisplay = EvalResDisplay
    { erdScope :: ER.ScopeId
    , erdSource :: CurPrevTag
    , erdVal :: ER.Val Type
    }

makeEvaluationResultView ::
    Monad m => AnimId -> EvalResDisplay -> ExprGuiM m (WithTextPos View)
makeEvaluationResultView animId res =
    do
        th <- Lens.view theme
        EvalView.make animId (erdVal res)
            <&>
            case erdSource res of
            Current -> id
            Prev -> Element.tint (Theme.staleResultTint (Theme.eval th))

data NeighborVals a = NeighborVals
    { prevNeighbor :: a
    , nextNeighbor :: a
    } deriving (Functor, Foldable, Traversable)

makeEvalView ::
    Monad m =>
    Maybe (NeighborVals (Maybe EvalResDisplay)) -> EvalResDisplay ->
    AnimId -> ExprGuiM m (WithTextPos View)
makeEvalView mNeighbours evalRes animId =
    do
        th <- Lens.view theme
        let Theme.Eval{..} = Theme.eval th
        let mkAnimId res =
                -- When we can scroll between eval view results we
                -- must encode the scope into the anim ID for smooth
                -- scroll to work.
                -- When we cannot, we'd rather not animate changes
                -- within a scrolled scope (use same animId).
                case mNeighbours of
                Nothing -> animId ++ ["eval-view"]
                Just _ -> animId ++ [encodeS (erdScope res)]
        let makeEvaluationResultViewBG res =
                addAnnotationBackground (mkAnimId res)
                <*> makeEvaluationResultView (mkAnimId res) res
                <&> (^. Align.tValue)
        let neighbourView n =
                Lens._Just makeEvaluationResultViewBG n
                <&> Lens.mapped %~ Element.scale (neighborsScaleFactor <&> realToFrac)
                <&> Lens.mapped %~ Element.pad (neighborsPadding <&> realToFrac)
                <&> fromMaybe Element.empty
        (prev, next) <-
            case mNeighbours of
            Nothing -> pure (Element.empty, Element.empty)
            Just (NeighborVals mPrev mNext) ->
                (,)
                <$> neighbourView mPrev
                <*> neighbourView mNext
        evalView <- makeEvaluationResultView (mkAnimId evalRes) evalRes
        let prevPos = Vector2 0 0.5 * evalView ^. Element.size - prev ^. Element.size
        let nextPos = Vector2 1 0.5 * evalView ^. Element.size
        evalView
            & Element.setLayers <>~ Element.translateLayers prevPos (prev ^. View.vAnimLayers)
            & Element.setLayers <>~ Element.translateLayers nextPos (next ^. View.vAnimLayers)
            & return

annotationSpacer :: Monad m => ExprGuiM m View
annotationSpacer = ExprGuiM.vspacer (Theme.valAnnotationSpacing . Theme.valAnnotation)

addAnnotationH ::
    (Functor f, Monad m) =>
    Widget.R ->
    (AnimId -> ExprGuiM m (WithTextPos View)) ->
    WideAnnotationBehavior -> AnimId ->
    ExprGuiM m
    (Responsive (f Widget.EventResult) ->
     Responsive (f Widget.EventResult))
addAnnotationH minWidth f wideBehavior animId =
    do
        vspace <- annotationSpacer
        annotationLayout <- f animId <&> (^. Align.tValue)
        processAnn <- processAnnotationGui animId wideBehavior
        let onAlignedWidget w =
                w /-/ vspace /-/
-- TODO (ALIGN):
--                AlignTo (w ^. Align.alignmentRatio . _1)
                (processAnn (w ^. Element.width) annotationLayout & Element.width %~ max minWidth)
        return $ Responsive.alignedWidget %~ onAlignedWidget

addInferredType ::
    (Functor f, Monad m) =>
    Type -> WideAnnotationBehavior -> AnimId ->
    ExprGuiM m (Responsive (f Widget.EventResult) -> Responsive (f Widget.EventResult))
addInferredType typ = addAnnotationH 0 (TypeView.make typ)

addEvaluationResult ::
    (Functor f, Monad m) =>
    Widget.R ->
    Maybe (NeighborVals (Maybe EvalResDisplay)) -> EvalResDisplay ->
    WideAnnotationBehavior -> AnimId ->
    ExprGuiM m
    (Responsive (f Widget.EventResult) ->
     Responsive (f Widget.EventResult))
-- REVIEW(Eyal): This is misleading when it refers to Previous results
addEvaluationResult minWidth mNeigh resDisp wideBehavior entityId =
    case (erdVal resDisp ^. ER.payload, erdVal resDisp ^. ER.body) of
    (T.TRecord T.CEmpty, _) ->
        addValBGWithColor Theme.evaluatedPathBGColor
    (_, ER.RFunc{}) -> return id
    _ -> addAnnotationH minWidth (makeEvalView mNeigh resDisp) wideBehavior entityId

parentExprFDConfig :: Config -> FocusDelegator.Config
parentExprFDConfig config = FocusDelegator.Config
    { FocusDelegator.focusChildKeys = Config.enterSubexpressionKeys config
    , FocusDelegator.focusChildDoc = E.Doc ["Navigation", "Enter subexpression"]
    , FocusDelegator.focusParentKeys = Config.leaveSubexpressionKeys config
    , FocusDelegator.focusParentDoc = E.Doc ["Navigation", "Leave subexpression"]
    }

disallowedNameChars :: String
disallowedNameChars = "[]\\`()"

nameEditFDConfig :: FocusDelegator.Config
nameEditFDConfig = FocusDelegator.Config
    { FocusDelegator.focusChildKeys = [MetaKey noMods MetaKey.Key'Enter]
    , FocusDelegator.focusChildDoc = E.Doc ["Edit", "Rename"]
    , FocusDelegator.focusParentKeys = [MetaKey noMods MetaKey.Key'Escape]
    , FocusDelegator.focusParentDoc = E.Doc ["Edit", "Done renaming"]
    }

-- | Add a diagonal line (top-left to right-bottom). Useful as a
-- "deletion" GUI annotation
addDiagonal ::
    (MonadReader env m, Element.HasAnimIdPrefix env, Element a) =>
    m (Draw.Color -> Draw.R -> a -> a)
addDiagonal =
    Element.subAnimId ["diagonal"] <&>
    \animId color thickness -> Element.topLayer %@~
    \sz ->
    Draw.convexPoly
    [ (0, thickness)
    , (0, 0)
    , (thickness, 0)
    , (1, 1-thickness)
    , (1, 1)
    , (1-thickness, 1)
    ]
    & Draw.tint color
    & void
    & Anim.singletonFrame 1 (animId ++ ["diagonal"])
    & Anim.scale sz
    & flip mappend

addDeletionDiagonal :: (Monad m, Element a) => ExprGuiM m (Widget.R -> a -> a)
addDeletionDiagonal =
    addDiagonal <*> (Lens.view Theme.theme <&> Theme.typeIndicatorErrorColor)

makeNameOriginEdit ::
    Monad m =>
    Name m -> Draw.Color -> Widget.Id ->
    ExprGuiM m (WithTextPos (Widget (T m Widget.EventResult)))
makeNameOriginEdit name color myId =
    ( FocusDelegator.make ?? nameEditFDConfig
      ?? FocusDelegator.FocusEntryParent ?? myId
      <&> (Align.tValue %~)
    ) <*> makeNameEdit name (WidgetIds.nameEditOf myId)
    & styleNameOrigin name color

styleNameOrigin :: Monad m => Name n -> Draw.Color -> ExprGuiM m b -> ExprGuiM m b
styleNameOrigin name color act =
    do
        style <- ExprGuiM.readStyle
        let textEditStyle =
                style
                ^. case name ^. Name.form of
                    Name.AutoGenerated {} -> Style.styleAutoNameOrigin
                    Name.Unnamed {}       -> Style.styleAutoNameOrigin
                    Name.Stored {}        -> Style.styleNameOrigin
                & TextEdit.sTextViewStyle . TextView.styleColor .~ color
        act & Reader.local (TextEdit.style .~ textEditStyle)

-- | A name edit without the collision suffixes
makeBareNameEdit ::
    Monad m =>
    Name m -> Widget.Id ->
    ExprGuiM m (WithTextPos (Widget (T m Widget.EventResult)))
makeBareNameEdit (Name form setName) myId =
    TextEdits.makeWordEdit
    ?? TextEdit.EmptyStrings visibleName ""
    ?? Property storedName setName
    ?? myId
    <&> Align.tValue . E.eventMap %~ E.filterChars (`notElem` disallowedNameChars)
    where
        (visibleName, _mCollision) = Name.visible form
        storedName = form ^. Name._Stored . _1

makeNameEdit ::
    Monad m =>
    Name m -> Widget.Id ->
    ExprGuiM m (WithTextPos (Widget (T m Widget.EventResult)))
makeNameEdit name myId =
    do
        mCollisionSuffix <- makeCollisionSuffixLabel mCollision
        makeBareNameEdit name myId
            <&> case mCollisionSuffix of
                Nothing -> id
                Just collisionSuffix ->
                    \nameEdit ->
                        (Aligned 0.5 nameEdit /|/ Aligned 0.5 collisionSuffix)
                        ^. Align.value
    & Reader.local (Element.animIdPrefix .~ Widget.toAnimId myId)
    where
        (_visibleName, mCollision) = name ^. Name.form & Name.visible

stdWrap ::
    Monad m =>
    Sugar.Payload m ExprGuiT.Payload ->
    ExprGuiM m (ExpressionGui m) ->
    ExprGuiM m (ExpressionGui m)
stdWrap pl act =
    do
        (res, holePicker) <-
            Reader.local (Element.animIdPrefix .~ animId) act
            & ExprGuiM.listenResultPicker
        exprEventMap <- ExprEventMap.make pl holePicker
        maybeAddAnnotationPl pl ?? res
            <&> addEvents exprEventMap
    where
        animId = Widget.toAnimId (WidgetIds.fromExprPayload pl)
        addEvents
            | ExprGuiT.isHoleResult pl = E.strongerEvents
            | otherwise = E.weakerEvents

parentDelegator ::
    (MonadReader env m, Config.HasConfig env, Widget.HasCursor env, Applicative f) =>
    Widget.Id -> m (Responsive (f Widget.EventResult) -> Responsive (f Widget.EventResult))
parentDelegator myId =
    FocusDelegator.make <*> (Lens.view Config.config <&> parentExprFDConfig)
    ?? FocusDelegator.FocusEntryChild ?? WidgetIds.notDelegatingId myId

stdWrapParentExpr ::
    Monad m =>
    Sugar.Payload m ExprGuiT.Payload ->
    Sugar.EntityId ->
    ExprGuiM m (ExpressionGui m) ->
    ExprGuiM m (ExpressionGui m)
stdWrapParentExpr pl delegateTo mkGui =
    mkGui
    & Widget.assignCursor (WidgetIds.fromExprPayload pl) (WidgetIds.fromEntityId delegateTo)
    & delegator
    & stdWrap pl
    where
        delegator
            | ExprGuiT.isHoleResult pl = id
            | otherwise = (parentDelegator (WidgetIds.fromExprPayload pl) <*>)

grammarLabel ::
    ( MonadReader env m
    , Theme.HasTheme env
    , TextView.HasStyle env
    , Element.HasAnimIdPrefix env
    ) => Text -> m (WithTextPos View)
grammarLabel text =
    do
        th <- Lens.view theme
        TextView.makeLabel text
            & Reader.local (TextView.color .~ Theme.grammarColor th)

addValBG :: (Monad m, Element a) => ExprGuiM m (a -> a)
addValBG = addValBGWithColor Theme.valFrameBGColor

addValBGWithColor ::
    (Monad m, Element a) =>
    (Theme -> Draw.Color) -> ExprGuiM m (a -> a)
addValBGWithColor color = Draw.backgroundColor <*> (Lens.view Theme.theme <&> color)

addValPadding :: (Monad m, Element a) => ExprGuiM m (a -> a)
addValPadding =
    Lens.view Theme.theme <&> Theme.valFramePadding <&> fmap realToFrac
    <&> Element.pad

addValFrame :: (Monad m, Element a) => ExprGuiM m (a -> a)
addValFrame =
    (.)
    <$> addValBG
    <*> addValPadding
    & Reader.local (Element.animIdPrefix <>~ ["val"])

-- TODO: This doesn't belong here
makeNameView :: Monad m => Name.Form -> AnimId -> ExprGuiM m (WithTextPos View)
makeNameView name animId =
    do
        mSuffixLabel <-
            makeCollisionSuffixLabel mCollision <&> Lens._Just %~ Aligned 0.5
        TextView.make ?? visibleName ?? animId
            <&> Aligned 0.5
            <&> maybe id (flip (/|/)) mSuffixLabel
            <&> (^. Align.value)
    & Reader.local (Element.animIdPrefix .~ animId)
    where
        (visibleName, mCollision) = Name.visible name

-- TODO: This doesn't belong here
makeCollisionSuffixLabel :: Monad m => Name.Collision -> ExprGuiM m (Maybe View)
makeCollisionSuffixLabel Name.NoCollision = return Nothing
makeCollisionSuffixLabel (Name.Collision suffix) =
    do
        th <- Lens.view theme
        let Theme.Name{..} = Theme.name th
        (Draw.backgroundColor ?? collisionSuffixBGColor)
            <*>
            (TextView.makeLabel (Text.pack (show suffix))
            & Reader.local (TextView.color .~ collisionSuffixTextColor)
            <&> Element.scale (realToFrac <$> collisionSuffixScaleFactor))
    <&> (^. Align.tValue)
    <&> Just

maybeAddAnnotationPl ::
    (Functor f, Monad m) =>
    Sugar.Payload x ExprGuiT.Payload ->
    ExprGuiM m (ExpressionGui f -> ExpressionGui f)
maybeAddAnnotationPl pl =
    do
        wideAnnotationBehavior <-
            if showAnnotation ^. ExprGuiT.showExpanded
            then return KeepWideAnnotation
            else ExprGuiM.isExprSelected pl <&> wideAnnotationBehaviorFromSelected
        maybeAddAnnotation wideAnnotationBehavior
            showAnnotation
            (pl ^. Sugar.plAnnotation)
            (Widget.toAnimId (WidgetIds.fromEntityId (pl ^. Sugar.plEntityId)))
    where
        showAnnotation = pl ^. Sugar.plData . ExprGuiT.plShowAnnotation

evaluationResult ::
    Monad m =>
    Sugar.Payload m ExprGuiT.Payload -> ExprGuiM m (Maybe (ER.Val Type))
evaluationResult pl =
    ExprGuiM.readMScopeId
    <&> valOfScope (pl ^. Sugar.plAnnotation)
    <&> Lens.mapped %~ erdVal

data EvalAnnotationOptions
    = NormalEvalAnnotation
    | WithNeighbouringEvalAnnotations (NeighborVals (Maybe Sugar.BinderParamScopeId))

maybeAddAnnotation ::
    (Functor f, Monad m) =>
    WideAnnotationBehavior -> ShowAnnotation -> Sugar.Annotation -> AnimId ->
    ExprGuiM m (ExpressionGui f -> ExpressionGui f)
maybeAddAnnotation = maybeAddAnnotationWith NormalEvalAnnotation

data AnnotationMode
    = AnnotationModeNone
    | AnnotationModeTypes
    | AnnotationModeEvaluation (Maybe (NeighborVals (Maybe EvalResDisplay))) EvalResDisplay

getAnnotationMode :: Monad m => EvalAnnotationOptions -> Sugar.Annotation -> ExprGuiM m AnnotationMode
getAnnotationMode opt annotation =
    do
        settings <- ExprGuiM.readSettings
        case settings ^. CESettings.sInfoMode of
            CESettings.None -> return AnnotationModeNone
            CESettings.Types -> return AnnotationModeTypes
            CESettings.Evaluation ->
                ExprGuiM.readMScopeId <&> valOfScope annotation
                <&> maybe AnnotationModeNone (AnnotationModeEvaluation neighbourVals)
    where
        neighbourVals =
            case opt of
            NormalEvalAnnotation -> Nothing
            WithNeighbouringEvalAnnotations neighbors ->
                neighbors <&> (>>= valOfScopePreferCur annotation . (^. Sugar.bParamScopeId))
                & Just

maybeAddAnnotationWith ::
    (Functor f, Monad m) =>
    EvalAnnotationOptions -> WideAnnotationBehavior -> ShowAnnotation ->
    Sugar.Annotation -> AnimId ->
    ExprGuiM m (ExpressionGui f -> ExpressionGui f)
maybeAddAnnotationWith opt wideAnnotationBehavior ShowAnnotation{..} annotation animId =
    getAnnotationMode opt annotation
    >>= \case
    AnnotationModeNone
        | _showExpanded -> withType
        | otherwise -> noAnnotation
    AnnotationModeEvaluation n v ->
        case _showInEvalMode of
        EvalModeShowNothing -> noAnnotation
        EvalModeShowType -> withType
        EvalModeShowEval -> withVal n v
    AnnotationModeTypes
        | _showInTypeMode -> withType
        | otherwise -> noAnnotation
    where
        noAnnotation = pure id
        -- concise mode and eval mode with no result
        inferredType = annotation ^. Sugar.aInferredType
        withType =
            addInferredType inferredType wideAnnotationBehavior animId
        withVal mNeighborVals scopeAndVal =
            do
                typeWidth <-
                    TypeView.make inferredType animId
                    <&> (^. Element.width)
                addEvaluationResult typeWidth mNeighborVals scopeAndVal wideAnnotationBehavior animId

valOfScope :: Sugar.Annotation -> CurAndPrev (Maybe ER.ScopeId) -> Maybe EvalResDisplay
valOfScope annotation mScopeIds =
    go
    <$> curPrevTag
    <*> annotation ^. Sugar.aMEvaluationResult
    <*> mScopeIds
    & fallbackToPrev
    where
        go _ _ Nothing = Nothing
        go tag ann (Just scopeId) =
            ann ^? Lens._Just . Lens.at scopeId . Lens._Just
            <&> EvalResDisplay scopeId tag

valOfScopePreferCur :: Sugar.Annotation -> ER.ScopeId -> Maybe EvalResDisplay
valOfScopePreferCur annotation = valOfScope annotation . pure . Just

listWithDelDests :: k -> k -> (a -> k) -> [a] -> [(k, k, a)]
listWithDelDests = ListUtils.withPrevNext

render :: Widget.R -> Responsive a -> WithTextPos (Widget a)
render width gui =
    (gui ^. Responsive.render)
    Responsive.LayoutParams
    { _layoutMode = Responsive.LayoutNarrow width
    , _layoutContext = Responsive.LayoutClear
    }
