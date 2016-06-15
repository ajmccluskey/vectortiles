{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE PatternSynonyms #-}
{-# LANGUAGE QuasiQuotes #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE StrictData #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE TypeSynonymInstances #-}
{-# LANGUAGE FlexibleInstances #-}

-- |
-- Module    : Geography.VectorTile.Geometry
-- Copyright : (c) Azavea, 2016
-- License   : Apache 2
-- Maintainer: Colin Woodbury <cwoodbury@azavea.com>

module Geography.VectorTile.Geometry
  ( -- * Geometries
    Geometry(..)
  , Point(..)
  , LineString(..)
  , Polygon(..)
  -- * Commands
  , Command(..)
  , commands
   -- * Z-Encoding
  , zig
  , unzig
  ) where

import           Control.Monad.Trans.State.Lazy
import           Data.Bits
import           Data.Int
import           Data.Monoid
import           Data.Text (Text,pack)
import qualified Data.Text as T
import qualified Data.Vector as V
import qualified Data.Vector.Unboxed as U
import           Data.Word
import           Text.Printf.TH

---

-- | Points in space. Using "Record Pattern Synonyms" here allows us to treat
-- `Point` like a normal ADT, while its implementation remains an unboxed
-- @(Int,Int)@.
type Point = (Int,Int)
pattern Point :: Int -> Int -> (Int, Int)
pattern Point{x, y} = (x, y)

-- | Points are just vectors in R2, and thus form a Vector space.
instance Monoid Point where
  mempty = Point 0 0
  (Point a b) `mappend` (Point a' b') = Point (a + a') (b + b')

-- | `newtype` compiles away to expose only the `U.Vector` of unboxed `Point`s
-- at runtime.
newtype LineString = LineString { points :: U.Vector Point } deriving (Eq,Show)

-- | Question: Do we want Polygons to know about their inner polygons?
-- If not, we get the better-performing implementation below.
data Polygon = Polygon { points :: U.Vector Point
                       , inner :: V.Vector Polygon } deriving (Eq,Show)

{-
-- | Very performant for the same reason as `LineString`.
newtype Polygon = Polygon { points :: U.Vector Point } deriving (Eq,Show)
-}

-- | Any classical type considered a GIS "geometry". These must be able
-- to convert between an encodable list of `Command`s.
class Geometry a where
  fromCommands :: [Command] -> Either Text (V.Vector a)
  toCommand :: a -> V.Vector Command
  toCommands :: V.Vector a -> V.Vector Command
  toCommands = V.concatMap toCommand

-- | A valid `R.Feature` of points should contain only `MoveTo`
-- commands.
instance Geometry Point where
  fromCommands [] = Right V.empty
  fromCommands (MoveTo p : cs) = V.cons p <$> fromCommands cs
  fromCommands (c:_) = Left $ [st|Invalid command found in Point feature: %s|] (show c)

  toCommand = undefined

-- Need a generalized parser for this, `pipes-parser` might work.
instance Geometry LineString where
  fromCommands cs = evalState (f cs) (0,0)
    where f = undefined

  toCommand = undefined

-- Need a generalized parser for this.
instance Geometry Polygon where
  fromCommands = undefined

  toCommand = undefined

-- | The possible commands, and the values they hold.
data Command = MoveTo (Int,Int) | LineTo (Int,Int) | ClosePath deriving (Eq,Show)

-- | Z-encode a 64-bit Int.
zig :: Int -> Word32
zig n = fromIntegral $ shift n 1 `xor` shift n (-63)

-- | Decode a Z-encoded Word32 into a 64-bit Int.
unzig :: Word32 -> Int
unzig n = fromIntegral (fromIntegral unzigged :: Int32)
  where unzigged = shift n (-1) `xor` negate (n .&. 1)

parseCommand :: Word32 -> Either T.Text (Int,Int)
parseCommand n = case (cid,count) of
  (1,m) -> Right $ both fromIntegral (1,m)
  (2,m) -> Right $ both fromIntegral (2,m)
  (7,1) -> Right (7,1)
  (7,m) -> Left $ "ClosePath was given a parameter count: " <> T.pack (show m)
  (m,_) -> Left $ [st|Invalid command integer %d found in: %X|] m n
  where cid = n .&. 7
        count = shift n (-3)

-- | Attempt to parse a list of Command/Parameter integers, as defined here:
--
-- https://github.com/mapbox/vector-tile-spec/tree/master/2.1#43-geometry-encoding
commands :: [Word32] -> Either T.Text [Command]
commands [] = Right []
commands (n:ns) = parseCommand n >>= f
  where f (1,count) = do
          mts <- map (MoveTo . both unzig) <$> pairs (take (count * 2) ns)
          (mts ++) <$> commands (drop (count * 2) ns)
        f (2,count) = do
          mts <- map (LineTo . both unzig) <$> pairs (take (count * 2) ns)
          (mts ++) <$> commands (drop (count * 2) ns)
        f (7,_) = (ClosePath :) <$> commands ns
        f _ = Left "Sentinel: You should never see this."

{- UTIL -}

pairs :: [a] -> Either T.Text [(a,a)]
pairs [] = Right []
pairs [_] = Left "Uneven number of parameters given."
pairs (x:y:zs) = ((x,y) :) <$>  pairs zs

both :: (a -> b) -> (a,a) -> (b,b)
both f (x,y) = (f x, f y)