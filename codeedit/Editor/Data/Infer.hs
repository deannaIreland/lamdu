{-# LANGUAGE GeneralizedNewtypeDeriving, TemplateHaskell, DeriveFunctor, DeriveFoldable, DeriveTraversable, DeriveDataTypeable,
             PatternGuards #-}
module Editor.Data.Infer
  ( Inferred(..), rExpression
  , Loaded, load
  , inferLoaded
  , updateAndInfer
  -- TODO: Expose only ref readers for InferNode (instead of .. and TypedValue)
  , InferNode(..), TypedValue(..)
  , Error(..), ErrorDetails(..)
  , RefMap, Context, ExprRef
  , Loader(..), InferActions(..)
  , initial
  -- Used for inferring independent expressions in an inner infer context
  -- (See hole apply forms).
  , newNodeWithScope
  , newTypedNodeWithScope
  ) where

import Control.Applicative (Applicative(..), (<$), (<$>))
import Control.Lens ((%=), (.=), (^.), (+=))
import Control.Monad (guard, liftM, unless, void, when)
import Control.Monad.Trans.Class (MonadTrans(..))
import Control.Monad.Trans.Either (EitherT(..))
import Control.Monad.Trans.State (StateT(..), State, runState)
import Control.Monad.Trans.Writer (Writer)
import Data.Binary (Binary(..), getWord8, putWord8)
import Data.Derive.Binary (makeBinary)
import Data.DeriveTH (derive)
import Data.Foldable (Foldable(..))
import Data.Function (on)
import Data.Functor.Identity (Identity(..))
import Data.IntMap (IntMap)
import Data.IntSet (IntSet)
import Data.Map (Map)
import Data.Maybe (fromMaybe, isJust, mapMaybe)
import Data.Monoid (Monoid(..))
import Data.Store.Guid (Guid)
import Data.Traversable (Traversable)
import Data.Tuple (swap)
import Data.Typeable (Typeable)
import Editor.Data.Infer.Rules (Rule(..))
import Editor.Data.Infer.Types
import qualified Control.Lens as Lens
import qualified Control.Lens.TH as LensTH
import qualified Control.Monad.Trans.Either as Either
import qualified Control.Monad.Trans.State as State
import qualified Data.Foldable as Foldable
import qualified Data.IntSet as IntSet
import qualified Data.Map as Map
import qualified Data.Set as Set
import qualified Data.Traversable as Traversable
import qualified Editor.Data as Data
import qualified Editor.Data.IRef as DataIRef
import qualified Editor.Data.Infer.Rules as Rules

type DefI = DataIRef.DefinitionIRef

toStateT :: Monad m => State s a -> StateT s m a
toStateT = State.mapStateT (return . runIdentity)

mkOrigin :: State Origin Origin
mkOrigin = do
  r <- State.get
  State.modify (+1)
  return r

newtype RuleRef = RuleRef { unRuleRef :: Int }
derive makeBinary ''RuleRef
instance Show RuleRef where
  show = ('E' :) . show . unRuleRef

-- Initial Pass:
-- Get Definitions' types expand.
-- Use expression's structures except for Apply.
--   (because an Apply can result in something else
--    but for example an Int or Lambda stays the same)
-- Add SimpleType, Union, LambdaOrPi, LambdaBodyType, Apply rules
-- Param types of Lambdas and Pis are of type Set
-- Pi result type is of type Set

-- When recursing on an expression, we remember the parent expression origins,
-- And we make sure not to add a sub-expression with a parent origin (that's a recursive structure).

data RefData def = RefData
  { _rExpression :: RefExpression def
  , _rRules :: [RuleRef] -- Rule id
  }
derive makeBinary ''RefData

--------------
--- RefMap:
data RefMap a = RefMap
  { _refs :: IntMap a
  , _nextRef :: Int
  }
LensTH.makeLenses ''RefData
LensTH.makeLenses ''RefMap
derive makeBinary ''RefMap

emptyRefMap :: RefMap a
emptyRefMap =
  RefMap
  { _refs = mempty
  , _nextRef = 0
  }

createEmptyRef :: State (RefMap a) Int
createEmptyRef = do
  key <- Lens.use nextRef
  nextRef += 1
  return key

refsAt :: Functor f => Int -> Lens.SimpleLensLike f (RefMap a) a
refsAt k = refs . Lens.at k . Lens.iso from Just
  where
    from = fromMaybe $ error msg
    msg = unwords ["intMapMod: key", show k, "not in map"]

createRef :: a -> State (RefMap a) Int
createRef initialVal = do
  ref <- createEmptyRef
  refsAt ref .= initialVal
  return ref
-------------- InferActions

data ErrorDetails def
  = MismatchIn
    (Data.Expression def ())
    (Data.Expression def ())
  | InfiniteExpression (Data.Expression def ())
  deriving (Show, Eq, Ord)
derive makeBinary ''ErrorDetails

data Error def = Error
  { errRef :: ExprRef
  , errMismatch ::
    ( Data.Expression def ()
    , Data.Expression def ()
    )
  , errDetails :: ErrorDetails def
  } deriving (Show, Eq, Ord)
derive makeBinary ''Error

newtype InferActions def m = InferActions
  { reportError :: Error def -> m ()
  }

--------------

data Context def = Context
  { _exprMap :: RefMap (RefData def)
  , _nextOrigin :: Int
  , _ruleMap :: RefMap (Rule def)
  } deriving (Typeable)
derive makeBinary ''Context

data InferState def m = InferState
  { _sContext :: Context def
  , _sBfsNextLayer :: IntSet
  , _sBfsCurLayer :: IntSet
  , _sActions :: InferActions def m
  }

data Inferred def a = Inferred
  { iStored :: a
  , iValue :: Data.Expression def ()
  , iType :: Data.Expression def ()
  , iScope :: Map Guid (Data.Expression def ())
  , iPoint :: InferNode def
  } deriving (Functor, Foldable, Traversable)

instance (Ord def, Binary def, Binary a) => Binary (Inferred def a) where
  get = Inferred <$> get <*> get <*> get <*> get <*> get
  put (Inferred a b c d e) = sequence_ [put a, put b, put c, put d, put e]

LensTH.makeLenses ''Context
LensTH.makeLenses ''InferState

-- ExprRefMap:

toRefExpression :: Data.Expression def () -> State Origin (RefExpression def)
toRefExpression = Traversable.mapM . const $ RefExprPayload mempty <$> mkOrigin

createRefExpr :: State (Context def) ExprRef
createRefExpr = do
  holeRefExpr <- Lens.zoom nextOrigin $ toRefExpression Data.pureHole
  liftM ExprRef . Lens.zoom exprMap . createRef $ RefData holeRefExpr mempty

exprRefsAt :: Functor f => ExprRef -> Lens.SimpleLensLike f (Context def) (RefData def)
exprRefsAt k = exprMap . refsAt (unExprRef k)

-- RuleRefMap

createEmptyRefRule :: State (Context def) RuleRef
createEmptyRefRule = liftM RuleRef $ Lens.zoom ruleMap createEmptyRef

ruleRefsAt :: Functor f => RuleRef -> Lens.SimpleLensLike f (Context def) (Rule def)
ruleRefsAt k = ruleMap . refsAt (unRuleRef k)

-------------

-- TODO: createTypeVal should use newNode, not vice versa.
-- For use in loading phase only!
-- We don't create additional Refs afterwards!
createTypedVal :: State (Context def) TypedValue
createTypedVal = TypedValue <$> createRefExpr <*> createRefExpr

newNodeWithScope :: Scope def -> Context def -> (Context def, InferNode def)
newNodeWithScope scope prevContext =
  (resultContext, InferNode tv scope)
  where
    (tv, resultContext) = runState createTypedVal prevContext

newTypedNodeWithScope :: Scope def -> ExprRef -> Context def -> (Context def, InferNode def)
newTypedNodeWithScope scope typ prevContext =
  (resultContext, InferNode (TypedValue newValRef typ) scope)
  where
    (newValRef, resultContext) = runState createRefExpr prevContext

initial :: Ord def => Maybe def -> (Context def, InferNode def)
initial mRecursiveDefI =
  (context, res)
  where
    (res, context) =
      (`runState` emptyContext) $ do
        rootTv <- createTypedVal
        let
          scope =
            case mRecursiveDefI of
            Nothing -> mempty
            Just recursiveDefI ->
              Map.singleton (Data.DefinitionRef recursiveDefI) (tvType rootTv)
        return $ InferNode rootTv scope
    emptyContext =
      Context
      { _exprMap = emptyRefMap
      , _nextOrigin = 0
      , _ruleMap = emptyRefMap
      }

--- InferT:

newtype InferT def m a =
  InferT { unInferT :: StateT (InferState def m) m a }
  deriving (Monad)

runInferT ::
  Monad m => InferState def m ->
  InferT def m a -> m (InferState def m, a)
runInferT state = liftM swap . (`runStateT` state) . unInferT

askActions :: Monad m => InferT def m (InferActions def m)
askActions = InferT $ Lens.use sActions

liftState :: Monad m => StateT (InferState def m) m a -> InferT def m a
liftState = InferT

{-# SPECIALIZE liftState :: StateT (InferState def Maybe) Maybe a -> InferT def Maybe a #-}
{-# SPECIALIZE liftState :: Monoid w => StateT (InferState def (Writer w)) (Writer w) a -> InferT def (Writer w) a #-}

instance MonadTrans (InferT def) where
  lift = liftState . lift

derefExpr ::
  (InferState def m, Data.Expression def (InferNode def, a)) ->
  (Data.Expression def (Inferred def a), Context def)
derefExpr (inferState, expr) =
  (derefNode <$> expr, resultContext)
  where
    resultContext = inferState ^. sContext
    derefNode (inferNode, s) =
      Inferred
      { iStored = s
      , iValue = deref . tvVal $ nRefs inferNode
      , iType = deref . tvType $ nRefs inferNode
      , iScope =
        Map.fromList . mapMaybe onScopeElement . Map.toList $ nScope inferNode
      , iPoint = inferNode
      }
    onScopeElement (Data.ParameterRef guid, ref) = Just (guid, deref ref)
    onScopeElement _ = Nothing
    deref ref = void $ resultContext ^. exprRefsAt ref . rExpression

getRefExpr :: Monad m => ExprRef -> InferT def m (RefExpression def)
getRefExpr ref = liftState $ Lens.use (sContext . exprRefsAt ref . rExpression)

{-# SPECIALIZE getRefExpr :: ExprRef -> InferT DefI Maybe (RefExpression DefI) #-}
{-# SPECIALIZE getRefExpr :: Monoid w => ExprRef -> InferT DefI (Writer w) (RefExpression DefI) #-}

executeRules :: (Eq def, Monad m) => InferT def m ()
executeRules = do
  curLayer <- liftState $ Lens.use sBfsNextLayer
  liftState $ sBfsCurLayer .= curLayer
  liftState $ sBfsNextLayer .= IntSet.empty
  unless (IntSet.null curLayer) $ do
    mapM_ processRule $ IntSet.toList curLayer
    executeRules
  where
    processRule key = do
      liftState $ sBfsCurLayer . Lens.contains key .= False
      Rule deps ruleClosure <-
        liftState $ Lens.use (sContext . ruleRefsAt (RuleRef key))
      refExps <- mapM getRefExpr deps
      mapM_ (uncurry setRefExpr) $ Rules.runClosure ruleClosure refExps

{-# SPECIALIZE executeRules :: InferT DefI Maybe () #-}
{-# SPECIALIZE executeRules :: Monoid w => InferT DefI (Writer w) () #-}

execInferT ::
  (Monad m, Eq def) => InferState def m ->
  InferT def m (Data.Expression def (InferNode def, a)) ->
  m (Data.Expression def (Inferred def a), Context def)
execInferT state act =
  liftM derefExpr .
  runInferT state $ do
    res <- act
    executeRules
    return res

{-# SPECIALIZE
  execInferT ::
    InferState DefI Maybe ->
    InferT DefI Maybe (Data.Expression DefI (InferNode DefI, a)) ->
    Maybe (Data.Expression DefI (Inferred DefI a), Context DefI)
  #-}

{-# SPECIALIZE
  execInferT ::
    Monoid w => InferState DefI (Writer w) ->
    InferT DefI (Writer w) (Data.Expression DefI (InferNode DefI, a)) ->
    (Writer w) (Data.Expression DefI (Inferred DefI a), Context DefI)
  #-}

newtype Loader def m = Loader
  { loadPureDefinitionType :: def -> m (Data.Expression def ())
  }

-- Initial expression for inferred value and type of a stored entity.
-- Types are returned only in cases of expanding definitions.
initialValExpr ::
  Data.Expression def () ->
  State Origin (RefExpression def)
initialValExpr (Data.Expression body ()) =
  toRefExpression $
  case body of
  Data.ExpressionApply _ -> Data.pureHole
  _ -> circumcized body
  where
    circumcized = Data.pureExpression . (Data.pureHole <$)

-- This is because platform's Either's Monad instance sucks
runEither :: EitherT l Identity a -> Either l a
runEither = runIdentity . runEitherT

guardEither :: l -> Bool -> EitherT l Identity ()
guardEither err False = Either.left err
guardEither _ True = return ()

originRepeat :: RefExpression def -> Bool
originRepeat =
  go Set.empty
  where
    go forbidden (Data.Expression body pl)
      | Set.member g forbidden = True
      | otherwise =
        Foldable.any (go (Set.insert g forbidden)) body
      where
        g = Lens.view rplOrigin pl

-- Merge two expressions:
-- If they do not match, return Nothing.
-- Holes match with anything, expand to the other expr.
-- Param guids and Origins come from the first expression.
-- If origins repeat, fail.
mergeExprs ::
  Eq def =>
  RefExpression def ->
  RefExpression def ->
  Either (ErrorDetails def) (RefExpression def)
mergeExprs p0 p1 =
  runEither $ do
    result <- Data.matchExpression onMatch onMismatch p0 p1
    guardEither (InfiniteExpression (void result)) . not $ originRepeat result
    return result
  where
    src `mergePayloadInto` dest =
      Lens.over rplSubstitutedArgs
      ((mappend . Lens.view rplSubstitutedArgs) src) dest
    onMatch x y = return $ y `mergePayloadInto` x
    onMismatch (Data.Expression (Data.ExpressionLeaf Data.Hole) s0) e1 =
      return $ (s0 `mergePayloadInto`) <$> e1
    onMismatch e0 (Data.Expression (Data.ExpressionLeaf Data.Hole) s1) =
      return $ (s1 `mergePayloadInto`) <$> e0
    onMismatch e0 e1 =
      Either.left $ MismatchIn (void e0) (void e1)

touch :: Monad m => ExprRef -> InferT def m ()
touch ref =
  liftState $ do
    nodeRules <- Lens.use (sContext . exprRefsAt ref . rRules)
    curLayer <- Lens.use sBfsCurLayer
    sBfsNextLayer %=
      ( mappend . IntSet.fromList
      . filter (not . (`IntSet.member` curLayer))
      . map unRuleRef
      ) nodeRules

{-# SPECIALIZE touch :: ExprRef -> InferT DefI Maybe () #-}
{-# SPECIALIZE touch :: Monoid w => ExprRef -> InferT DefI (Writer w) () #-}

setRefExpr :: (Eq def, Monad m) => ExprRef -> RefExpression def -> InferT def m ()
setRefExpr ref newExpr = do
  curExpr <- liftState $ Lens.use (sContext . exprRefsAt ref . rExpression)
  case mergeExprs curExpr newExpr of
    Right mergedExpr -> do
      let
        isChange = not $ equiv mergedExpr curExpr
        isHole =
          case mergedExpr ^. Data.eValue of
          Data.ExpressionLeaf Data.Hole -> True
          _ -> False
      when isChange $ touch ref
      when (isChange || isHole) $
        liftState $ sContext . exprRefsAt ref . rExpression .= mergedExpr
    Left details -> do
      report <- liftM reportError askActions
      lift $ report Error
        { errRef = ref
        , errMismatch = (void curExpr, void newExpr)
        , errDetails = details
        }
  where
    equiv x y =
      isJust $
      Data.matchExpression compareSubsts ((const . const) Nothing) x y
    compareSubsts x y = guard $ (x ^. rplSubstitutedArgs) == (y ^. rplSubstitutedArgs)

{-# SPECIALIZE setRefExpr :: ExprRef -> RefExpression DefI -> InferT DefI Maybe () #-}
{-# SPECIALIZE setRefExpr :: Monoid w => ExprRef -> RefExpression DefI -> InferT DefI (Writer w) () #-}

liftOriginState :: Monad m => State Origin a -> InferT def m a
liftOriginState = liftState . Lens.zoom (sContext . nextOrigin) . toStateT

liftContextState :: Monad m => State (Context def) a -> InferT def m a
liftContextState = liftState . Lens.zoom sContext . toStateT

exprIntoContext ::
  (Monad m, Ord def) => Scope def ->
  Loaded def a ->
  InferT def m (Data.Expression def (InferNode def, a))
exprIntoContext rootScope (Loaded rootExpr defTypes) = do
  defTypesRefs <-
    Traversable.mapM defTypeIntoContext $
    Map.mapKeys Data.DefinitionRef defTypes
  -- mappend prefers left, so it is critical we put rootScope
  -- first. defTypesRefs may contain the loaded recursive defI because
  -- upon resumption, we load without giving the root defI, so its
  -- type does get (unnecessarily) loaded.
  go (rootScope `mappend` defTypesRefs) =<<
    liftContextState
    (Traversable.mapM addTypedVal rootExpr)
  where
    defTypeIntoContext defType = do
      ref <- liftContextState createRefExpr
      setRefExpr ref =<< liftOriginState (toRefExpression defType)
      return ref
    addTypedVal x = liftM ((,) x) $ createTypedVal
    go scope (Data.Expression body (s, createdTV)) = do
      inferNode <- toInferNode scope (void <$> body) createdTV
      newBody <-
        case body of
        Data.ExpressionLambda lam -> goLambda Data.makeLambda scope lam
        Data.ExpressionPi lam -> goLambda Data.makePi scope lam
        _ -> Traversable.mapM (go scope) body
      return $ Data.Expression newBody (inferNode, s)
    goLambda cons scope (Data.Lambda paramGuid paramType result) = do
      paramTypeDone <- go scope paramType
      let
        paramTypeRef = tvVal . nRefs . fst $ paramTypeDone ^. Data.ePayload
        newScope = Map.insert (Data.ParameterRef paramGuid) paramTypeRef scope
      resultDone <- go newScope result
      return $ cons paramGuid paramTypeDone resultDone

    toInferNode scope body tv = do
      let
        typedValue@(TypedValue val _) =
          tv
          { tvType =
            case body of
            Data.ExpressionLeaf (Data.GetVariable varRef)
              | Just x <- Map.lookup varRef scope -> x
            _ -> tvType tv
          }
      initialVal <- liftOriginState . initialValExpr $ Data.pureExpression body
      setRefExpr val initialVal
      return $ InferNode typedValue scope

ordNub :: Ord a => [a] -> [a]
ordNub = Set.toList . Set.fromList

data Loaded def a = Loaded
  { _lExpr :: Data.Expression def a
  , _lDefTypes :: Map def (Data.Expression def ())
  } deriving (Typeable)
instance (Binary a, Binary def, Ord def) => Binary (Loaded def a) where
  get = Loaded <$> get <*> get
  put (Loaded a b) = put a >> put b

load ::
  (Monad m, Ord def) => Loader def m ->
  Maybe def -> Data.Expression def a ->
  m (Loaded def a)
load loader mRecursiveDef expr =
  liftM (Loaded expr) loadDefTypes
  where
    loadDefTypes =
      liftM Map.fromList .
      mapM loadType $ ordNub
      [ defI
      | Data.ExpressionLeaf (Data.GetVariable (Data.DefinitionRef defI)) <-
        map (Lens.view Data.eValue) $ Data.subExpressions expr
      , Just defI /= mRecursiveDef
      ]
    loadType defI = liftM ((,) defI) $ loadPureDefinitionType loader defI

addRule :: Rule def -> State (InferState def m) ()
addRule rule = do
  ruleRef <- makeRule
  mapM_ (addRuleId ruleRef) $ ruleInputs rule
  sBfsNextLayer . Lens.contains (unRuleRef ruleRef) .= True
  where
    makeRule = do
      ruleRef <- Lens.zoom sContext createEmptyRefRule
      sContext . ruleRefsAt ruleRef .= rule
      return ruleRef
    addRuleId ruleRef ref = sContext . exprRefsAt ref . rRules %= (ruleRef :)

updateAndInfer ::
  (Eq def, Monad m) => InferActions def m -> Context def ->
  [(ExprRef, Data.Expression def ())] ->
  Data.Expression def (Inferred def a) ->
  m (Data.Expression def (Inferred def a), Context def)
updateAndInfer actions prevContext updates expr =
  execInferT inferState $ do
    mapM_ doUpdate updates
    return $ f <$> expr
  where
    inferState = InferState prevContext mempty mempty actions
    f inferred = (iPoint inferred, iStored inferred)
    doUpdate (ref, newExpr) =
      setRefExpr ref =<<
      (liftOriginState . toRefExpression) newExpr

inferLoaded ::
  (Ord def, Monad m) =>
  InferActions def m -> Loaded def a ->
  Context def -> InferNode def ->
  m (Data.Expression def (Inferred def a), Context def)
inferLoaded actions loadedExpr initialContext node =
  execInferT initialState $ do
    expr <- exprIntoContext (nScope node) loadedExpr
    liftState . toStateT $ do
      let
        addUnionRules f =
          mapM_ addRule $ on Rules.union (f . nRefs) node . fst $ expr ^. Data.ePayload
      addUnionRules tvVal
      addUnionRules tvType
      rules <-
        Lens.zoom (sContext . nextOrigin) . Rules.makeAll $ nRefs . fst <$> expr
      mapM_ addRule rules
    return expr
  where
    initialState = InferState initialContext mempty mempty actions

{-# SPECIALIZE
  inferLoaded ::
    InferActions DefI Maybe -> Loaded DefI a -> Context DefI -> InferNode DefI ->
    Maybe (Data.Expression DefI (Inferred DefI a), Context DefI)
  #-}
{-# SPECIALIZE
  inferLoaded ::
    Monoid w => InferActions DefI (Writer w) -> Loaded DefI a -> Context DefI -> InferNode DefI ->
    Writer w (Data.Expression DefI (Inferred DefI a), Context DefI)
  #-}
