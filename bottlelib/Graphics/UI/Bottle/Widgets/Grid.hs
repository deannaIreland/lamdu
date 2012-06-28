{-# LANGUAGE TemplateHaskell, OverloadedStrings #-}
module Graphics.UI.Bottle.Widgets.Grid(
  Grid, KGrid(..), make, makeKeyed, unkey, getElement,
  atGridMCursor,
  atGridContent,
  GridElement(..),
  atGridElementRect,
  atGridElementSdwd,
  Cursor, toWidget, toWidgetBiased)
where

import Control.Applicative (liftA2)
import Control.Arrow (first, second)
import Control.Monad (msum, (>=>))
import Data.Function (on)
import Data.List (foldl', transpose, find, minimumBy, sortBy, groupBy)
import Data.List.Utils (index, enumerate2d)
import Data.MRUMemo (memo)
import Data.Maybe (isJust, fromMaybe, catMaybes, mapMaybe)
import Data.Monoid (Monoid(..))
import Data.Ord (comparing)
import Data.Vector.Vector2 (Vector2(..))
import Graphics.UI.Bottle.Rect (Rect(..))
import Graphics.UI.Bottle.SizeRange (Size)
import Graphics.UI.Bottle.Sized (Sized(..))
import Graphics.UI.Bottle.Widget (Widget(..), SizeDependentWidgetData(..), R)
import Graphics.UI.Bottle.Widgets.StdKeys (DirKeys(..), stdDirKeys)
import qualified Data.AtFieldTH as AtFieldTH
import qualified Data.Vector.Vector2 as Vector2
import qualified Graphics.UI.Bottle.Direction as Direction
import qualified Graphics.UI.Bottle.EventMap as EventMap
import qualified Graphics.UI.Bottle.Rect as Rect
import qualified Graphics.UI.Bottle.Sized as Sized
import qualified Graphics.UI.Bottle.Widget as Widget
import qualified Graphics.UI.Bottle.Widgets.GridView as GridView
import qualified Graphics.UI.GLFW as GLFW

type Cursor = Vector2 Int

length2d :: [[a]] -> Vector2 Int
length2d xs = Vector2 (foldl' max 0 . map length $ xs) (length xs)

capCursor :: Vector2 Int -> Vector2 Int -> Vector2 Int
capCursor size = fmap (max 0) . liftA2 min (fmap (subtract 1) size)

data NavDests f = NavDests
  { leftOfCursor
  , aboveCursor
  , rightOfCursor
  , belowCursor
  , topCursor
  , leftMostCursor
  , bottomCursor
  , rightMostCursor :: Maybe (Widget.EnterResult f)
  }

mkNavDests :: Size -> Rect -> [[Widget.MEnter f]] -> Cursor -> NavDests f
mkNavDests widgetSize selfRect mEnterss cursor@(Vector2 cursorX cursorY) = NavDests
  { leftOfCursor    = giveSelf . reverse $ take cursorX curRow
  , aboveCursor     = giveSelf . reverse $ take cursorY curColumn
  , rightOfCursor   = giveSelf $ drop (cursorX+1) curRow
  , belowCursor     = giveSelf $ drop (cursorY+1) curColumn

  , topCursor       = giveEdge (Vector2 Nothing (Just 0)) $ take (min 1 cursorY) curColumn
  , leftMostCursor  = giveEdge (Vector2 (Just 0) Nothing) $ take (min 1 cursorX) curRow
  , bottomCursor    = giveEdge (Vector2 Nothing (Just 1)) . take 1 . reverse $ drop (cursorY+1) curColumn
  , rightMostCursor = giveEdge (Vector2 (Just 1) Nothing) . take 1 . reverse $ drop (cursorX+1) curRow
  }
  where
    curRow = fromMaybe [] $ index cappedY mEnterss
    curColumn = fromMaybe [] $ index cappedX (transpose mEnterss)
    Vector2 cappedX cappedY = capCursor size cursor
    size = length2d mEnterss

    give dir = fmap ($ Direction.RelativePos dir) . msum
    giveSelf = give selfRect
    giveEdge edge = give Rect
      { Rect.rectTopLeft =
          liftA2 fromMaybe (Rect.rectTopLeft selfRect) $
          liftA2 (fmap . (*)) widgetSize edge
      , Rect.rectSize =
          liftA2 fromMaybe (Rect.rectSize selfRect) $
          (fmap . fmap) (const 0) edge
      }


mkNavEventmap
  :: NavDests f -> (Widget.EventHandlers f, Widget.EventHandlers f)
mkNavEventmap navDests = (weakMap, strongMap)
  where
    weakMap = mconcat . catMaybes $ [
      movementk "left"       (keysLeft  stdDirKeys) leftOfCursor,
      movementk "right"      (keysRight stdDirKeys) rightOfCursor,
      movementk "up"         (keysUp    stdDirKeys) aboveCursor,
      movementk "down"       (keysDown  stdDirKeys) belowCursor,
      movementk "more left"  [GLFW.KeyHome]         leftMostCursor,
      movementk "more right" [GLFW.KeyEnd]          rightMostCursor
      ]
    strongMap = mconcat . catMaybes $ [
      movementk "top"       [GLFW.KeyPageup]    topCursor,
      movementk "bottom"    [GLFW.KeyPagedown]  bottomCursor,
      movement "leftmost"  [ctrlK GLFW.KeyHome] leftMostCursor,
      movement "rightmost" [ctrlK GLFW.KeyEnd]  rightMostCursor
      ]
    k = EventMap.ModKey EventMap.noMods
    ctrlK = EventMap.ModKey EventMap.ctrl
    movementk dirName = movement dirName . map k
    movement dirName events =
      fmap
        (EventMap.keyPresses
         events
         ("Move " ++ dirName) .
         Widget.enterResultEvent) .
      ($ navDests)

getCursor :: [[Widget k]] -> Maybe Cursor
getCursor =
  fmap cursorOf . find (isFocused . snd) . concat . enumerate2d
  where
    cursorOf ((row, column), _) = Vector2 column row

data GridElement f = GridElement
  { gridElementRect :: Rect
  , gridElementSdwd :: SizeDependentWidgetData f
  }

data KGrid key f = KGrid {
  gridMCursor :: Maybe Cursor,
  gridContent :: Sized [[(key, GridElement f)]]
  }

AtFieldTH.make ''GridElement
AtFieldTH.make ''KGrid

type Grid = KGrid ()

makeKeyed :: [[(key, Widget f)]] -> KGrid key f
makeKeyed children = KGrid {
  gridMCursor = getCursor $ (map . map) snd children,
  gridContent =
   GridView.makeGeneric (second . translate) $
   (map . map) (keyIntoSized . second Widget.content) children
  }
  where
    keyIntoSized (key, sized) = fmap ((,) key) sized
    translate rect =
      GridElement rect .
      Widget.translateSizeDependentWidgetData (Rect.rectTopLeft rect)

unkey :: [[Widget f]] -> [[((), Widget f)]]
unkey = (map . map) ((,) ())

getElement :: (Show key, Eq key) => key -> [(key, GridElement f)] -> GridElement f
getElement key =
  fromMaybe (error errorMsg) . lookup key
  where
    errorMsg = "getElement: " ++ show key ++ " not found in Grid!"

make :: [[Widget f]] -> Grid f
make = makeKeyed . unkey

helper ::
  (Size -> [[Widget.MEnter f]] -> Widget.MEnter f) ->
  KGrid key f -> Widget f
helper combineEnters (KGrid mCursor sChildren) =
  Widget
    { isFocused = isJust mCursor
    , content =
      Sized.atFromSize combineSizeDependentWidgetDatas $
      (fmap . map . map) snd sChildren
    }
  where
    combineSizeDependentWidgetDatas mkGridElementss size =
      maybe unselectedSizeDependentWidgetData makeSizeDependentWidgetData mCursor
      where
        sdwdss = (map . map) gridElementSdwd $ mkGridElementss size
        framess = (map . map) sdwdFrame sdwdss
        mEnterss = (map . map) sdwdMaybeEnter sdwdss
        frame = mconcat $ concat framess
        mEnter = combineEnters size mEnterss

        unselectedSizeDependentWidgetData = SizeDependentWidgetData
          { sdwdFrame = frame
          , sdwdMaybeEnter = mEnter
          , sdwdEventMap = mempty
          , sdwdFocalArea = Rect 0 size
          }

        makeSizeDependentWidgetData cursor@(Vector2 x y) = SizeDependentWidgetData
          { sdwdFrame = frame
          , sdwdMaybeEnter = mEnter
          , sdwdEventMap = makeEventMap sdwd navDests
          , sdwdFocalArea = sdwdFocalArea sdwd
          }
          where
            navDests = mkNavDests size (sdwdFocalArea sdwd) mEnterss cursor
            sdwd = sdwdss !! y !! x

        makeEventMap sdwd navDests =
          mconcat [strongMap, sdwdEventMap sdwd, weakMap]
          where
            (weakMap, strongMap) = mkNavEventmap navDests

tupleToVector2 :: (a, a) -> Vector2 a
tupleToVector2 (y, x) = Vector2 x y

minimumOn :: Ord b => (a -> b) -> [a] -> a
minimumOn = minimumBy . comparing

sortOn :: Ord b => (a -> b) -> [a] -> [a]
sortOn = sortBy . comparing

groupOn :: Eq b => (a -> b) -> [a] -> [[a]]
groupOn = groupBy . ((==) `on`)

groupSortOn :: Ord b => (a -> b) -> [a] -> [[a]]
groupSortOn f = groupOn f . sortOn f

toWidget :: KGrid key f -> Widget f
toWidget =
  helper makeMEnter
  where
    makeMEnter size children = chooseClosest childEnters
      where
        childEnters =
          mapMaybe indexIntoMaybe .
          (concatMap . map . first) tupleToVector2 $
          enumerate2d children

        chooseClosest [] = Nothing
        chooseClosest _ = Just byDirection

        byDirection dir =
          minimumOn (Rect.distance dirRect . Widget.enterResultRect) .
          map ($ dir) $ filteredByEdge edge
          where
            dirRect = Direction.fold (Rect 0 0) id dir
            edge = asEdge size dirRect

        filteredByEdge = memo $ \(Vector2 hEdge vEdge) ->
          map snd .
          concat . take 1 . groupSortOn ((* (-hEdge)) . Vector2.fst . fst) .
          concat . take 1 . groupSortOn ((* (-vEdge)) . Vector2.snd . fst) $
          childEnters
        indexIntoMaybe (i, m) = fmap ((,) i) m

asEdge :: Vector2 R -> Rect -> Vector2 Int
asEdge size rect =
  Vector2 hEdge vEdge
  where
    hEdge = boolToInt rightEdge - boolToInt leftEdge
    vEdge = boolToInt bottomEdge - boolToInt topEdge
    boolToInt False = 0
    boolToInt True = 1
    Vector2 leftEdge topEdge =
      fmap (<= 0) (Rect.bottomRight rect)
    Vector2 rightEdge bottomEdge =
      liftA2 (>=) (Rect.rectTopLeft rect) size

-- ^ If unfocused, will enters the given child when entered
toWidgetBiased :: Cursor -> KGrid key f -> Widget f
toWidgetBiased (Vector2 x y) =
  helper . const $ index y >=> index x >=> id
