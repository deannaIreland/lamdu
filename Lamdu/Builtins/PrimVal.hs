{-# LANGUAGE OverloadedStrings #-}
module Lamdu.Builtins.PrimVal
    ( KnownPrim(..)
    , fromKnown, toKnown
    , floatId, bytesId
    , floatType, bytesType
    , nameOf
    ) where

import           Data.Binary.Utils (encodeS, decodeS)
import           Data.ByteString (ByteString)
import           Lamdu.Expr.Type (Type)
import qualified Lamdu.Expr.Type as T
import qualified Lamdu.Expr.Val as V

data KnownPrim
    = Float Double
    | Bytes ByteString
    deriving (Eq, Ord, Show)

bytesId :: T.NominalId
bytesId = "BI:bytes"

floatId :: T.NominalId
floatId = "BI:float"

nameOf :: T.NominalId -> String
nameOf p
    | p == bytesId = "Bytes"
    | p == floatId = "Num"
    | otherwise = error $ "Invalid prim id: " ++ show p

floatType :: Type
floatType = T.TInst floatId mempty

bytesType :: Type
bytesType = T.TInst bytesId mempty

toKnown :: V.PrimVal -> KnownPrim
toKnown (V.PrimVal litId bytes)
    | litId == floatId = Float (decodeS bytes)
    | litId == bytesId = Bytes bytes
    | otherwise = error $ "Unknown prim id: " ++ show litId

fromKnown :: KnownPrim -> V.PrimVal
fromKnown (Float dbl) = V.PrimVal floatId (encodeS dbl)
fromKnown (Bytes bytes) = V.PrimVal bytesId bytes
