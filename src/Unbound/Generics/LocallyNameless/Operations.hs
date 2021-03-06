-- |
-- Module     : Unbound.Generics.LocallyNameless.Operations
-- Copyright  : (c) 2014, Aleksey Kliger
-- License    : BSD3 (See LICENSE)
-- Maintainer : Aleksey Kliger
-- Stability  : experimental
--
-- Operations on terms and patterns that contain names.
{-# LANGUAGE RankNTypes, ScopedTypeVariables #-}
module Unbound.Generics.LocallyNameless.Operations
       (-- * Equivalence, free variables, freshness
         aeq
       , fvAny
       , fv
       , freshen
       , lfreshen
       , swaps
         -- * Binding, unbinding
       , Bind
       , bind
       , unbind
       , lunbind
       , unbind2
       , lunbind2
       , unbind2Plus
         -- * Rebinding, embedding
       , Rebind
       , rebind
       , unrebind
       , Embed(..)
       , embed
       , unembed
       ) where

import Control.Applicative (Applicative)
import Control.Monad (MonadPlus(mzero))
import Data.Functor.Contravariant (Contravariant)
import Data.Monoid ((<>))
import Data.Typeable (Typeable, cast)
import Unbound.Generics.LocallyNameless.Alpha
import Unbound.Generics.LocallyNameless.Fresh
import Unbound.Generics.LocallyNameless.LFresh
import Unbound.Generics.LocallyNameless.Name
import Unbound.Generics.LocallyNameless.Bind
import Unbound.Generics.LocallyNameless.Embed (Embed(..))
import Unbound.Generics.LocallyNameless.Rebind
import Unbound.Generics.LocallyNameless.Internal.Fold (toListOf, justFiltered)
import Unbound.Generics.PermM

-- | @'aeq' t1 t2@ returns @True@ iff @t1@ and @t2@ are alpha-equivalent terms.
aeq :: Alpha a => a -> a -> Bool
aeq = aeq' initialCtx

-- | @'fvAny'@ returns a fold over any names in a term @a@.
--
-- @
--   fvAny :: Alpha a => Fold a AnyName
-- @
fvAny :: (Alpha a, Contravariant f, Applicative f) => (AnyName -> f AnyName) -> a -> f a
fvAny = fvAny' initialCtx

-- | @'fv'@ returns the free @b@ variables of term @a@.
--
-- @
--  fv :: (Alpha a, Typeable b) => Fold a (Name b)
-- @
fv :: forall a f b . (Alpha a, Typeable b, Contravariant f, Applicative f)
      => (Name b -> f (Name b)) -> a -> f a
fv = fvAny . justFiltered f
  where f :: AnyName -> Maybe (Name b)
        f (AnyName n) = cast n

-- | Freshen a pattern by replacing all old binding 'Name's with new
--   fresh 'Name's, returning a new pattern and a @'Perm' 'Name'@
--   specifying how 'Name's were replaced.
freshen :: (Alpha p, Fresh m) => p -> m (p, Perm AnyName)
freshen = freshen' (patternCtx initialCtx)

-- | \"Locally\" freshen a pattern, replacing all binding names with
--   new names that are not already \"in scope\". The second argument
--   is a continuation, which takes the renamed term and a permutation
--   that specifies how the pattern has been renamed.  The resulting
--   computation will be run with the in-scope set extended by the
--   names just generated.
lfreshen :: (Alpha p, LFresh m) => p -> (p -> Perm AnyName -> m b) -> m b
lfreshen = lfreshen' (patternCtx initialCtx)

-- | Apply the given permutation of variable names to the given term.
swaps :: Alpha t => Perm AnyName -> t -> t
swaps = swaps' initialCtx

  
-- | @'bind' p t@ closes over the variables of pattern @p@ in the term @t@
bind :: (Alpha p, Alpha t) => p -> t -> Bind p t
bind p t = B p (close initialCtx p t)

-- | @'unbind' b@ lets you descend beneath a binder @b :: 'Bind' p t@
-- by returning the pair of the pattern @p@ and the term @t@ where the
-- variables in the pattern have been made globally fresh with respect
-- to the freshness monad @m@.
unbind :: (Alpha p, Alpha t, Fresh m) => Bind p t -> m (p, t)
unbind (B p t) = do
  (p', _) <- freshen p
  return (p', open initialCtx p' t)

-- | @lunbind@ opens a binding in an 'LFresh' monad, ensuring that the
--   names chosen for the binders are /locally/ fresh.  The components
--   of the binding are passed to a /continuation/, and the resulting
--   monadic action is run in a context extended to avoid choosing new
--   names which are the same as the ones chosen for this binding.
--
--   For more information, see the documentation for the 'LFresh' type
--   class.
lunbind :: (LFresh m, Alpha p, Alpha t) => Bind p t -> ((p, t) -> m c) -> m c
lunbind (B p t) cont =
  lfreshen p (\x _ -> cont (x, open initialCtx x t))


-- | Simultaneously unbind two patterns in two terms, returning 'Nothing' if
-- the two patterns don't bind the same number of variables.
unbind2 :: (Fresh m, Alpha p1, Alpha p2, Alpha t1, Alpha t2)
           => Bind p1 t1
           -> Bind p2 t2
           -> m (Maybe (p1, t1, p2, t2))
unbind2 (B p1 t1) (B p2 t2) = do
      case mkPerm (toListOf fvAny p2) (toListOf fvAny p1) of
         Just pm -> do
           (p1', pm') <- freshen p1
           return $ Just (p1', open initialCtx p1' t1,
                          swaps (pm' <> pm) p2, open initialCtx p1' t2)
         Nothing -> return Nothing

-- | Simultaneously 'lunbind' two patterns in two terms in the 'LFresh' monad,
-- passing @Just (p1, t1, p2, t2)@ to the continuation such that the patterns
-- are permuted such that they introduce the same free names, or 'Nothing' if
-- the number of variables differs.
lunbind2 :: (LFresh m, Alpha p1, Alpha p2, Alpha t1, Alpha t2)
            => Bind p1 t1
            -> Bind p2 t2
            -> (Maybe (p1, t1, p2, t2) -> m c)
            -> m c
lunbind2 (B p1 t1) (B p2 t2) cont =
  case mkPerm (toListOf fvAny p2) (toListOf fvAny p1) of
    Just pm ->
      lfreshen p1 $ \p1' pm' ->
      cont $ Just (p1', open initialCtx p1' t1,
                   swaps (pm' <> pm) p2, open initialCtx p1' t2)
    Nothing -> cont Nothing

-- | Simultaneously unbind two patterns in two terms, returning 'mzero' if
-- the patterns don't bind the same number of variables.
unbind2Plus :: (MonadPlus m, Fresh m, Alpha p1, Alpha p2, Alpha t1, Alpha t2)
         => Bind p1 t1
         -> Bind p2 t2
         -> m (p1, t1, p2, t2)
unbind2Plus bnd bnd' = maybe mzero return =<< unbind2 bnd bnd'


-- | @'rebind' p1 p2@ is a smart constructor for 'Rebind'.  It
-- captures the variables of pattern @p1@ that occur within @p2@ in
-- addition to providing binding occurrences for all the variables of @p1@ and @p2@
rebind :: (Alpha p1, Alpha p2) => p1 -> p2 -> Rebind p1 p2
rebind p1 p2 = Rebnd p1 (close (patternCtx initialCtx) p1 p2)

-- | @'unrebind' p@ is the elimination form for 'Rebind'. It is not
-- monadic (unlike 'unbind') because a @Rebind@ pattern can only occur
-- somewhere in a pattern position of a 'Bind', and therefore 'unbind'
-- must have already been called and all names apropriately
-- 'freshen'ed.
unrebind :: (Alpha p1, Alpha p2) => Rebind p1 p2 -> (p1, p2)
unrebind (Rebnd p1 p2) = (p1, open (patternCtx initialCtx) p1 p2)

-- | An alias for 'Embed'
embed :: t -> Embed t
embed = Embed

-- | @'unembed' p@ extracts the term embedded in the pattern @p@.
unembed :: Embed t -> t
unembed (Embed t) = t
