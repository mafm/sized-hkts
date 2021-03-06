{-# language BangPatterns #-}
{-# language FlexibleContexts #-}
{-# language FlexibleInstances, MultiParamTypeClasses #-}
{-# language PatternSynonyms #-}
{-# language RankNTypes #-}
{-# language TemplateHaskell #-}
{-# language TupleSections #-}
{-# language QuantifiedConstraints #-}
{-# options_ghc -fno-warn-unused-top-binds #-}
module Check.Entailment
  ( solve
  , entails
  , simplify
  , SMeta(..), composeSSubs
  , Theory(..), theoryToList, insertLocal, mapTy
  , HasGlobalTheory(..)
  , HasSizeMetas(..)
  , freshSMeta
  , findSMeta
  )
where

import Bound (abstract)
import Bound.Var (Var(..), unvar)
import Control.Applicative (empty)
import Control.Lens.Getter (view, use)
import Control.Lens.Lens (Lens', lens)
import Control.Lens.Setter ((.~), (.=))
import Control.Lens.TH (makeLenses)
import Control.Monad (guard)
import Control.Monad.Except (MonadError, runExcept, throwError)
import Control.Monad.State.Strict (MonadState, runStateT, get, put)
import Control.Monad.Trans.Maybe (MaybeT, runMaybeT)
import Data.Bifunctor (first)
import Data.Foldable (asum, foldl')
import Data.Function ((&))
import Data.Map (Map)
import qualified Data.Map as Map
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Void (Void, absurd)

import Check.TCState.FilterTypes (FilterTypes, filterTypes, mapTypes)
import Error.TypeError (TypeError(..), renderTyName)
import IR (Constraint(..), Kind)
import Size((.@), Size(..), pattern Var)
import Syntax (TMeta(..), TMeta, pattern TypeM, Span(Unknown))
import Unify.KMeta (HasKindMetas(..))
import Unify.TMeta (HasTypeMetas(..), freshTMeta, solveMetas_Constraint)
import Unify.Type (unifyType)

newtype SMeta = SMeta Int
  deriving (Eq, Ord, Show)

data Theory ty
  = Theory
  { _thGlobal :: Map (Constraint Void) (Size Void)
  , _thLocal :: Map (Constraint ty) SMeta
  } deriving Show
makeLenses ''Theory

theoryToList :: Theory ty -> [(Size (Either SMeta sz), Constraint ty)]
theoryToList (Theory gbl lcl) =
  Map.foldrWithKey
    (\c m -> (:) (Var $ Left m, c))
    (Map.foldrWithKey (\c s -> (:) (absurd <$> s, absurd <$> c)) [] gbl)
    lcl

class HasGlobalTheory s where
  globalTheory :: Lens' s (Map (Constraint Void) (Size Void))

instance HasGlobalTheory (Theory ty) where
  globalTheory = thGlobal

insertLocal :: Ord ty => Constraint ty -> SMeta -> Theory ty -> Theory ty
insertLocal k v (Theory gbl lcl) = Theory gbl $! Map.insert k v lcl

mapTy :: Ord ty' => (ty -> ty') -> Theory ty -> Theory ty'
mapTy f (Theory gbl lcl) = Theory gbl (Map.mapKeys (fmap f) lcl)

applySSubs ::
  Map SMeta (Size (Either SMeta sz)) ->
  Size (Either SMeta sz) ->
  Size (Either SMeta sz)
applySSubs subs s =
  s >>= either (\m -> fromMaybe (Var $ Left m) $ Map.lookup m subs) (Var . Right)

findSMeta ::
  Map SMeta (Size (Either SMeta sz)) ->
  SMeta ->
  Size (Either SMeta sz)
findSMeta s m =
  case Map.lookup m s of
    Nothing -> Var $ Left m
    Just term -> term >>= either (findSMeta s) (Var . Right)

composeSSubs ::
  Map SMeta (Size (Either SMeta sz)) ->
  Map SMeta (Size (Either SMeta sz)) ->
  Map SMeta (Size (Either SMeta sz))
composeSSubs a b =
  fmap (applySSubs a) b <> a

class HasSizeMetas s where
  nextSMeta :: Lens' s SMeta

freshSMeta :: (MonadState s m, HasSizeMetas s) => m SMeta
freshSMeta = do
  SMeta t <- use nextSMeta
  nextSMeta .= SMeta (t+1)
  pure $ SMeta t

withoutMetas :: (ty -> ty') -> Constraint (Either TMeta ty) -> Maybe (Constraint ty')
withoutMetas f = traverse (either (const Nothing) (Just . f))

solve ::
  ( MonadState (s ty) m
  , FilterTypes s, HasTypeMetas s
  , forall x. HasKindMetas (s x), forall x. HasSizeMetas (s x)
  , MonadError TypeError m
  , Ord ty
  ) =>
  Map Text Kind ->
  Lens' ty Span ->
  (ty -> Either Int Text) ->
  (ty -> Kind) ->
  Theory (Either TMeta ty) ->
  [(SMeta, Constraint (Either TMeta ty))] ->
  m
    ( [(SMeta, Constraint (Either TMeta ty))]
    , Map SMeta (Size (Either SMeta Void))
    )
solve _ _ _ _ _ [] = pure ([], mempty)
solve kindScope spans tyNames kinds theory (c:cs) = do
  m_res <- runMaybeT $ simplify kindScope spans tyNames kinds theory c
  case m_res of
    Nothing -> do
      c' <- solveMetas_Constraint (snd c)
      case withoutMetas (Right . renderTyName . tyNames) c' of
        Nothing -> do
          (cs', sols') <- solve kindScope spans tyNames kinds theory cs
          pure ((fst c, c') : cs', sols')
        Just c'' -> throwError $ CouldNotDeduce c''
    Just (cs', sols) -> do
      (cs'', sols') <- solve kindScope spans tyNames kinds theory (cs' <> cs)
      pure (cs'', composeSSubs sols' sols)

entails ::
  ( MonadState (s ty) m, HasKindMetas (s ty), HasTypeMetas s, HasSizeMetas (s ty)
  , Eq ty
  ) =>
  Map Text Kind ->
  Lens' ty Span ->
  (ty -> Either Int Text) ->
  (ty -> Kind) ->
  (Size (Either SMeta sz), Constraint (Either TMeta ty)) ->
  (SMeta, Constraint (Either TMeta ty)) ->
  MaybeT m
    ( [(SMeta, Constraint (Either TMeta ty))]
    , Map SMeta (Size (Either SMeta sz))
    )
entails kindScope spans tyNames kinds (antSize, ant) (consVar, cons) =
  case ant of
    -- antSize : forall (x : k). _
    CForall _ k a -> do
      meta <- freshTMeta Unknown k
      entails kindScope spans tyNames kinds (antSize, unvar (\() -> Left meta) id <$> a) (consVar, cons)
    -- antSize : _ -> _
    CImplies a b -> do
      bvar <- freshSMeta
      (bAssumes, ssubs) <- entails kindScope spans tyNames kinds (Var $ Left bvar, b) (consVar, cons)
      avar <- freshSMeta
      pure
        ( (avar, a) : bAssumes
        , composeSSubs (Map.singleton bvar $ antSize .@ Var (Left avar)) ssubs
        )
    -- antSize : Word64
    CSized t ->
      case cons of
        CSized t' -> do
          st <- get
          let res = runExcept $ runStateT (unifyType kindScope spans tyNames kinds (TypeM t') (TypeM t)) st
          case res of
            Left{} -> do
              empty
            Right ((), st') -> do
              put st'
              pure ([], Map.singleton consVar antSize)
        _ -> error "consequent not simple enough"

simplify ::
  ( MonadState (s ty) m
  , FilterTypes s, HasTypeMetas s
  , forall x. HasKindMetas (s x), forall x. HasSizeMetas (s x)
  , MonadError TypeError m
  , Ord ty
  ) =>
  Map Text Kind ->
  Lens' ty Span ->
  (ty -> Either Int Text) ->
  (ty -> Kind) ->
  Theory (Either TMeta ty) ->
  (SMeta, Constraint (Either TMeta ty)) ->
  m
    ( [(SMeta, Constraint (Either TMeta ty))]
    , Map SMeta (Size (Either SMeta sz))
    )
simplify kindScope spans tyNames kinds !theory (consVar, cons) =
  case cons of
    CForall m_n k a -> do
      ameta <- freshSMeta
      es <- get
      ((aAssumes, asubs), es') <-
        flip runStateT (mapTypes F es) $ do
          (aAssumes, asubs) <-
            simplify
              kindScope
              (lens
                {- TODO: what about the span for the bound variable? This is bad lens otherwise -}
                (unvar (\() -> Unknown) (view spans))
                (unvar (\() _ -> B ()) (\t sp -> F $ t & spans .~ sp))
              ) 
              (unvar (\() -> maybe (Left 0) Right m_n) (first (+1) . tyNames))
              (unvar (\() -> k) kinds)
              (mapTy (fmap F) theory)
              (ameta, sequence <$> a)
          -- solve metas now, because any solutions that involve skolem variables
          -- will be filtered out by `filterTypes`
          aAssumes' <- (traverse.traverse) solveMetas_Constraint aAssumes
          pure (aAssumes', asubs)
      put $ filterTypes (unvar (\() -> Nothing) Just) es'
      pure
        ( (fmap.fmap) (CForall m_n k . fmap sequence) aAssumes
        , Map.singleton consVar (fromMaybe (error "ameta not solved") $ Map.lookup ameta asubs)
        )
    CImplies a b -> do
      ameta <- freshSMeta
      bmeta <- freshSMeta
      (bAssumes, bsubs) <- simplify kindScope spans tyNames kinds (insertLocal a ameta theory) (bmeta, b)
      bAssumes' <- traverse (\assume -> (, assume) <$> freshSMeta) bAssumes
      pure
        ( (\(v, (_, c)) -> (v, CImplies a c)) <$> bAssumes'
        , Map.singleton consVar $
          Lam
            (abstract (either (guard . (ameta ==)) (const Nothing)) $
             applySSubs
               (foldl'
                  (\acc (new, (old, _)) ->
                     Map.insert old ((Var $ Left new) .@ (Var $ Left ameta)) acc
                  )
                  mempty
                  bAssumes'
               )
               (fromMaybe (error "bmeta not solved") $ Map.lookup bmeta bsubs)
            )
        )
    CSized{} -> do
      m_res <-
        runMaybeT . asum $
          (\(antVar, ant) -> entails kindScope spans tyNames kinds (antVar, ant) (consVar, cons)) <$>
          theoryToList theory
      case m_res of
        Nothing -> do
          cons' <- solveMetas_Constraint cons
          throwError $ CouldNotDeduce ((fmap.fmap) (renderTyName . tyNames) cons')
        Just (assumes, sub) -> pure (assumes, sub)
