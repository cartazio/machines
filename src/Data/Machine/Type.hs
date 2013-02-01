{-# LANGUAGE GADTs #-}
{-# LANGUAGE Rank2Types #-}
{-# LANGUAGE FlexibleInstances #-}
-----------------------------------------------------------------------------
-- |
-- Module      :  Data.Machine.Type
-- Copyright   :  (C) 2012 Edward Kmett
-- License     :  BSD-style (see the file LICENSE)
--
-- Maintainer  :  Edward Kmett <ekmett@gmail.com>
-- Stability   :  provisional
-- Portability :  rank-2, GADTs
--
----------------------------------------------------------------------------
module Data.Machine.Type
  (
  -- * Machines
    Machine(..)
  , run_
  , run
  -- ** Building machines from plans
  , construct
  , repeatedly
  , before
  -- * Reshaping machines
  , fit
  , pass
  ) where

import Control.Applicative
import Control.Category
import Control.Monad
import Data.Foldable
import Data.Machine.Plan
import Data.Pointed
import Data.Semigroup
import Prelude hiding ((.),id)

-------------------------------------------------------------------------------
-- Transduction Machines
-------------------------------------------------------------------------------

-- | A 'Machine' reads from a number of inputs and may yield results before stopping.
--
-- Note: A 'Machine' is usually constructed from 'Plan', so it does not need to be CPS'd.
--
-- (Now that we have a 'Monad' of our own, this is no longer completely true.)
data Machine m a
  = Yield a (Machine m a)
  | forall i. Await (i -> Machine m a) (m i) (Machine m a)
  | Stop

instance Functor (Machine m) where
  fmap f (Yield o k) = Yield (f o) (fmap f k)
  fmap f (Await ka m kf) = Await (fmap f . ka) m (fmap f kf)
  fmap _ Stop = Stop
  {-# INLINEABLE fmap #-}

instance Applicative (Machine m) where
  pure a = Yield a Stop
  {-# INLINE pure #-}

  (<*>) = ap
  {-# INLINE (<*>) #-}

instance Alternative (Machine m) where
  Stop <|> n          = n
  Yield a m <|> n     = Yield a (m <> n)
  Await ka k kf <|> n = Await (\i -> ka i <|> n) k (kf <|> n)
  {-# INLINE (<|>) #-}
  empty = Stop
  {-# INLINE empty #-}

instance Monad (Machine m) where
  return a = Yield a Stop
  {-# INLINE return #-}
  m0 >>= k = go m0 where
    go Stop            = Stop
    go (Yield a m)     = mappend (k a) (go m)
    go (Await ka m kf) = Await (go . ka) m (go kf)
  {-# INLINE (>>=) #-}

instance MonadPlus (Machine m) where
  mplus = (<|>)
  {-# INLINE mplus #-}
  mzero = empty
  {-# INLINE mzero #-}

instance Pointed (Machine m) where
  point a = Yield a Stop
  {-# INLINE point #-}

instance Semigroup (Machine m a) where
  (<>) = (<|>)
  {-# INLINE (<>) #-}

instance Monoid (Machine m a) where
  mempty = Stop
  {-# INLINE mempty #-}
  mappend = (<|>)
  {-# INLINE mappend #-}

instance Foldable (Machine m) where
  foldMap _ Stop          = mempty
  foldMap f (Yield o k)   = f o `mappend` foldMap f k
  foldMap f (Await _ _ e) = foldMap f e
  {-# INLINEABLE foldMap #-}

run_ :: MonadPlus m => Machine m b -> m ()
run_ Stop            = return ()
run_ (Yield _ k)     = run_ k
run_ (Await ks m ke) = mplus (m >>= run_ . ks) (run_ ke)
{-# INLINEABLE run_ #-}

run :: MonadPlus m => Machine m b -> m [b]
run Stop            = return []
run (Yield o m)     = (o:) `liftM` run m
run (Await ks m ke) = mplus (m >>= run . ks) (run ke)
{-# INLINEABLE run #-}

-- |
-- Connect different kinds of machines.
--
-- @'fit' 'id' = 'id'@
fit :: (forall a. m a -> n a) -> Machine m o -> Machine n o
fit f = go where
  go (Yield o k)     = Yield o (go k)
  go Stop            = Stop
  go (Await g kir h) = Await (go . g) (f kir) (go h)
{-# INLINE fit #-}

-- | Compile a machine to a model.
construct :: Plan o m a -> Machine m o
construct (Plan m) = m (const Stop) Yield Await Stop
{-# INLINE construct #-}

-- | Generates a model that runs a machine until it stops, then start it up again.
--
-- @'repeatedly' m = 'construct' ('Control.Monad.forever' m)@
repeatedly :: Plan o m a -> Machine m o
repeatedly (Plan m) = r where r = m (const r) Yield Await Stop
{-# INLINE repeatedly #-}

-- | Evaluate a machine until it stops, and then yield answers according to the supplied model.
before :: Machine m o -> Plan o m a -> Machine m o
before n p = n <|> construct p
{-# INLINE before #-}

-- | Given a handle, ignore all other inputs and just stream input from that handle.
--
-- @
-- 'pass' 'id' :: 'Data.Machine.Process.Process' a a
-- 'pass' 'Data.Machine.Tee.L'  :: 'Data.Machine.Tee.Tee' a b a
-- 'pass' 'Data.Machine.Tee.R'  :: 'Data.Machine.Tee.Tee' a b b
-- 'pass' 'Data.Machine.Wye.X'  :: 'Data.Machine.Wye.Wye' a b a
-- 'pass' 'Data.Machine.Wye.Y'  :: 'Data.Machine.Wye.Wye' a b b
-- 'pass' 'Data.Machine.Wye.Z'  :: 'Data.Machine.Wye.Wye' a b (Either a b)
-- @
pass :: m o -> Machine m o
pass k = repeatedly $ do
  a <- awaits k
  yield a
{-# INLINE pass #-}
