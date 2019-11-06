module Lamdu.Sugar.Convert.Apply
    ( convert
    ) where

import qualified Control.Lens as Lens
import           Control.Monad (MonadPlus)
import           Control.Monad.Trans.Except.Extended (runMatcherT, justToLeft)
import           Control.Monad.Trans.Maybe (MaybeT(..))
import qualified Data.Map as Map
import           Data.Maybe.Extended (maybeToMPlus)
import qualified Data.Property as Property
import qualified Data.Set as Set
import           Hyper
import           Hyper.Type.AST.FuncType (funcIn)
import           Hyper.Type.AST.Row (freExtends, freRest)
import           Hyper.Type.AST.Scheme (sTyp)
import           Lamdu.Calc.Definition (Deps, depsGlobalTypes)
import           Lamdu.Calc.Term (Val)
import qualified Lamdu.Calc.Term as V
import qualified Lamdu.Calc.Type as T
import qualified Lamdu.Expr.IRef as ExprIRef
import qualified Lamdu.Sugar.Config as Config
import           Lamdu.Sugar.Convert.Case (convertAppliedCase)
import           Lamdu.Sugar.Convert.Expression.Actions (addActions, addActionsWith, subexprPayloads)
import           Lamdu.Sugar.Convert.Fragment (convertAppliedHole)
import qualified Lamdu.Sugar.Convert.Input as Input
import           Lamdu.Sugar.Convert.Monad (ConvertM)
import qualified Lamdu.Sugar.Convert.Monad as ConvertM
import           Lamdu.Sugar.Internal
import qualified Lamdu.Sugar.Internal.EntityId as EntityId
import           Lamdu.Sugar.Lens (childPayloads, getVarName)
import qualified Lamdu.Sugar.PresentationModes as PresentationModes
import           Lamdu.Sugar.Types

import           Lamdu.Prelude

convert ::
    (Monad m, Monoid a) =>
    ConvertM.PositionInfo ->
    Annotated (Input.Payload m a) (V.App V.Term) ->
    ConvertM m (ExpressionU m a)
convert posInfo x@(Ann (Const exprPl) app@(V.App funcI argI)) =
    runMatcherT $
    do
        (funcS, argS) <-
            do
                argS <- ConvertM.convertSubexpression argI & lift
                convertAppliedHole posInfo x argS & justToLeft
                funcS <- ConvertM.convertSubexpression funcI & lift
                protectedSetToVal <- lift ConvertM.typeProtectedSetToVal
                pure
                    ( if Lens.has (hVal . _BodyHole) argS
                      then
                          let dst = argI ^. hAnn . Lens._Wrapped . Input.stored . Property.pVal
                              deleteAction =
                                  EntityId.ofValI dst <$
                                  protectedSetToVal (exprPl ^. Input.stored) dst
                          in  funcS
                              & hAnn . Lens._Wrapped . pActions . mSetToHole ?~ deleteAction
                      else funcS
                    , argS
                    )
        convertAppliedCase app funcS argS exprPl & justToLeft
        convertLabeled (app ^.. htraverse1) funcS argS exprPl & justToLeft
        convertPrefix (app ^.. htraverse1) funcS argS exprPl & lift

validateDefParamsMatchArgs ::
    MonadPlus m =>
    V.Var ->
    Tree (Composite InternalName i o) (Ann a) ->
    Deps ->
    m ()
validateDefParamsMatchArgs var record frozenDeps =
    do
        defArgs <-
            frozenDeps ^?
                depsGlobalTypes . Lens.at var . Lens._Just
                . _Pure . sTyp . _Pure . T._TFun . funcIn
                . _Pure . T._TRecord . T.flatRow
            & maybeToMPlus
        defArgs ^? freRest . _Pure . T._REmpty & maybeToMPlus
        let sFields =
                (record ^.. cItems . traverse . ciTag . tagRefTag . tagVal) <>
                (record ^.. cPunnedItems . traverse . hVal . Lens._Wrapped . getVarName . inTag)
                & Set.fromList
        guard (sFields == Map.keysSet (defArgs ^. freExtends))

convertLabeled ::
    (Monad m, Foldable f, Monoid a) =>
    f (Val (Input.Payload m a)) ->
    ExpressionU m a -> ExpressionU m a -> Input.Payload m a ->
    MaybeT (ConvertM m) (ExpressionU m a)
convertLabeled subexprs funcS argS exprPl =
    do
        Lens.view (ConvertM.scConfig . Config.sugarsEnabled . Config.labeledApply) >>= guard
        -- Make sure it's a not a param, get the var
        sBinderVar <- funcS ^? hVal . _BodyGetVar . _GetBinder & maybeToMPlus
        -- Make sure it is not a "let" but a "def" (recursive or external)
        _ <- sBinderVar ^? bvForm . _GetDefinition & maybeToMPlus
        -- Make sure the argument is a record
        record <- argS ^? hVal . _BodyRecord & maybeToMPlus
        -- that is closed
        Lens.has (cTail . _ClosedComposite) record & guard
        -- with at least 2 fields
        length (record ^. cItems) + length (record ^. cPunnedItems) >= 2 & guard
        frozenDeps <- Lens.view ConvertM.scFrozenDeps <&> Property.value
        let var = sBinderVar ^. bvVar
        -- If it is an external (non-recursive) def (i.e: not in
        -- scope), make sure the def (frozen) type is inferred to have
        -- closed record of same parameters
        recursiveRef <- Lens.view (ConvertM.scScopeInfo . ConvertM.siRecursiveRef)
        validateDefParamsMatchArgs var record frozenDeps
            & unless (Just var == (recursiveRef <&> (^. ConvertM.rrDefI) <&> ExprIRef.globalId))
        let getArg field =
                AnnotatedArg
                    { _aaTag = field ^. ciTag . tagRefTag
                    , _aaExpr = field ^. ciExpr
                    }
        bod <-
            PresentationModes.makeLabeledApply
            (Ann (Const (funcS ^. hAnn . Lens._Wrapped)) (Const sBinderVar))
            (record ^. cItems <&> getArg) (record ^. cPunnedItems) exprPl
            <&> BodyLabeledApply & lift
        let userPayload =
                subexprPayloads subexprs (bod ^.. childPayloads)
                & mconcat
        addActionsWith userPayload exprPl bod & lift

convertPrefix ::
    (Monad m, Foldable f, Monoid a) =>
    f (Val (Input.Payload m a)) ->
    ExpressionU m a -> ExpressionU m a -> Input.Payload m a ->
    ConvertM m (ExpressionU m a)
convertPrefix subexprs funcS argS applyPl =
    do
        protectedSetToVal <- ConvertM.typeProtectedSetToVal
        let del =
                protectedSetToVal (applyPl ^. Input.stored)
                (funcS ^. hAnn . Lens._Wrapped . pInput . Input.stored & Property.value)
                <&> EntityId.ofValI
        BodySimpleApply App
            { _appFunc = funcS
            , _appArg = argS & hVal . _BodyHole . holeMDelete ?~ del
            } & addActions subexprs applyPl
