{-# language FlexibleContexts #-}
module Unify.TMeta
  ( HasTypeMetas(..)
  , freshTMeta
  , getTMeta
  , getTMetaKind
  , solveMetas_Constraint
  , solveTMetas_Expr
  , solveTMetas_Type
  )
where

import Bound.Var (Var(..))
import Control.Lens.Getter (use)
import Control.Lens.Lens (Lens')
import Control.Lens.Setter ((.=), (%=))
import Control.Monad.State.Strict (MonadState)
import Data.Bitraversable (bitraverse)
import Data.Map (Map)
import qualified Data.Map as Map

import IR (Kind(..))
import qualified IR
import Syntax (Span, TMeta(..), TypeM, unTypeM, Type(..))
import Unify.KMeta (HasKindMetas, solveKMetas)

class HasTypeMetas s where
  nextTMeta :: Lens' (s ty) Int
  tmetaKinds :: Lens' (s ty) (Map TMeta Kind)
  tmetaSolutions :: Lens' (s ty) (Map TMeta (TypeM ty))

getTMeta ::
  (MonadState (s ty) m, HasTypeMetas s) =>
  TMeta ->
  m (Maybe (TypeM ty))
getTMeta v = do
  sols <- use tmetaSolutions
  pure $ Map.lookup v sols

getTMetaKind :: (MonadState (s ty) m, HasTypeMetas s) => TMeta -> m (Maybe Kind)
getTMetaKind v = do
  ks <- use tmetaKinds
  pure $ Map.lookup v ks

freshTMeta :: (MonadState (s ty) m, HasTypeMetas s) => Span -> Kind -> m TMeta
freshTMeta sp k = do
  t <- use nextTMeta
  nextTMeta .= t+1
  tmetaKinds %= Map.insert (TMeta sp t) k
  pure $ TMeta sp t

solveTMetas_Type ::
  (MonadState (s ty) m, HasTypeMetas s) =>
  (ty -> a) ->
  Type (Either TMeta a) ->
  m (Type (Either TMeta a))
solveTMetas_Type d = go d
  where
    go ::
      (MonadState (s ty) m, HasTypeMetas s) =>
      (ty -> a) ->
      Type (Either TMeta a) ->
      m (Type (Either TMeta a))
    go depth t =
      case t of
        TVar a ->
          case a of
            Left m ->
              getTMeta m >>=
              maybe
                (pure $ TVar $ Left m)
                (go depth . unTypeM . fmap depth)
            Right x -> pure $ TVar $ Right x
        TApp sp a b -> TApp sp <$> go depth a <*> go depth b
        TInt32 sp -> pure $ TInt32 sp
        TBool sp -> pure $ TBool sp
        TPtr sp -> pure $ TPtr sp
        TFun sp ts -> TFun sp <$> traverse (go depth) ts
        TName sp n -> pure $ TName sp n

solveMetas_Constraint ::
  (MonadState (s ty) m, HasTypeMetas s, HasKindMetas (s ty)) =>
  IR.Constraint (Either TMeta ty) ->
  m (IR.Constraint (Either TMeta ty))
solveMetas_Constraint = go id
  where
    go ::
      (MonadState (s ty) m, HasTypeMetas s, HasKindMetas (s ty)) =>
      (ty -> a) ->
      IR.Constraint (Either TMeta a) ->
      m (IR.Constraint (Either TMeta a))
    go depth c =
      case c of
        IR.CSized t ->
          IR.CSized <$> solveTMetas_Type depth t
        IR.CForall n k rest ->
          IR.CForall n <$>
          solveKMetas k <*>
          (fmap sequence <$> go (F . depth) (sequence <$> rest))
        IR.CImplies a b ->
          IR.CImplies <$>
          go depth a <*>
          go depth b

solveTMetas_Expr ::
  (MonadState (s ty) m, HasTypeMetas s) =>
  IR.Expr (Either TMeta ty) tm ->
  m (IR.Expr (Either TMeta ty) tm)
solveTMetas_Expr = go
  where
    goCase ::
      (MonadState (s ty) m, HasTypeMetas s) =>
      IR.Case (Either TMeta ty) tm ->
      m (IR.Case (Either TMeta ty) tm)
    goCase (IR.Case name args e) =
      IR.Case name args <$> go e

    go ::
      (MonadState (s ty) m, HasTypeMetas s) =>
      IR.Expr (Either TMeta ty) tm ->
      m (IR.Expr (Either TMeta ty) tm)
    go e =
      case e of
        IR.Var a -> pure $ IR.Var a
        IR.Name n -> pure $ IR.Name n
        IR.Let bs rest ->
          IR.Let <$>
          traverse (bitraverse (traverse go) (solveTMetas_Type id)) bs <*>
          go rest
        IR.Inst n args ->
          IR.Inst n <$>
          traverse
            (solveTMetas_Type id)
            args
        IR.Ctor n ts ->
          IR.Ctor n <$>
          traverse
            (solveTMetas_Type id)
            ts
        IR.Call f args t ->
          IR.Call <$>
          go f <*>
          traverse go args <*>
          solveTMetas_Type id t
        IR.Int32 n -> pure $ IR.Int32 n
        IR.Add a b -> IR.Add <$> go a <*> go b
        IR.BTrue -> pure $ IR.BTrue
        IR.BFalse -> pure $ IR.BFalse
        IR.New a t -> IR.New <$> go a <*> solveTMetas_Type id t
        IR.Deref a -> IR.Deref <$> go a
        IR.Project a b -> (\a' -> IR.Project a' b) <$> go a
        IR.Match a inTy b resTy ->
          IR.Match <$>
          go a <*>
          solveTMetas_Type id inTy <*>
          traverse goCase b <*>
          solveTMetas_Type id resTy
