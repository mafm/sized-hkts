{-# language FlexibleContexts #-}
module Unify.Kind (unifyKind) where

import Control.Lens.Setter ((%=))
import Control.Monad.Except (MonadError, throwError)
import Control.Monad.State (MonadState)
import qualified Data.Map as Map
import Data.Monoid (Any(..))

import Error.TypeError (TypeError(..))
import IR (Kind(..), foldKMeta)
import Unify.KMeta (HasKindMetas, getKMeta, kmetaSolutions)

unifyKind ::
  ( MonadState s m, HasKindMetas s
  , MonadError TypeError m
  ) =>
  Kind ->
  Kind ->
  m ()
unifyKind expected actual =
  case expected of
    KVar v | KVar v' <- actual, v == v' -> pure ()
    KVar v -> solveLeft v actual
    KArr a b ->
      case actual of
        KVar v -> solveRight expected v
        KArr a' b' -> do
          unifyKind a a'
          unifyKind b b'
        _ -> throwError $ KindMismatch expected actual
    KType ->
      case actual of
        KVar v -> solveRight expected v
        KType -> pure ()
        _ -> throwError $ KindMismatch expected actual
  where
    solveLeft v k = do
      m_k' <- getKMeta v
      case m_k' of
        Nothing ->
          if getAny $ foldKMeta (Any . (v ==)) k
          then throwError $ KindOccurs v k
          else kmetaSolutions %= Map.insert v k
        Just k' -> unifyKind k' k
    solveRight k v = do
      m_k' <- getKMeta v
      case m_k' of
        Nothing ->
          if getAny $ foldKMeta (Any . (v ==)) k
          then throwError $ KindOccurs v k
          else kmetaSolutions %= Map.insert v k
        Just k' -> unifyKind k k'