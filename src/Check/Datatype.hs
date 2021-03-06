{-# language BangPatterns #-}
{-# language FlexibleContexts #-}
{-# language OverloadedLists, OverloadedStrings #-}
{-# language PatternSynonyms #-}
{-# language ScopedTypeVariables #-}
{-# language QuantifiedConstraints #-}
module Check.Datatype
  ( checkADT
  , HasDatatypeFields(..)
  , getFieldType
  , HasDatatypeCtors(..)
  , getConstructor
  )
where

import Bound (abstract)
import Bound.Var (Var(..), unvar)
import Control.Lens.Lens (Lens')
import Control.Lens.Getter (use, uses)
import Control.Monad (guard)
import Control.Monad.Except (MonadError, throwError)
import Control.Monad.State.Strict (MonadState)
import Control.Monad.Writer (runWriter, tell)
import Data.Foldable (foldlM, traverse_)
import Data.Map (Map)
import qualified Data.Map as Map
import Data.Monoid (Any(..))
import Data.Set (Set)
import qualified Data.Set as Set
import Data.Text (Text)
import Data.Validation (Validation(..), validation)
import Data.Vector (Vector)
import qualified Data.Vector as Vector
import Data.Void (Void, absurd)

import Check.Entailment
  ( HasGlobalTheory, HasSizeMetas
  , SMeta, Theory(..)
  , freshSMeta, findSMeta
  , globalTheory
  , solve
  )
import Check.Kind (checkKind)
import Check.TCState.FilterTypes (FilterTypes)
import Error.TypeError (TypeError(..))
import IR (Constraint(..), KMeta, Kind(..), substKMeta)
import qualified IR
import Size (Size(..), plusSize, maxSize, sizeConstraintFor)
import Syntax (Index(..), indexSpan, getIndex, Span(..), Type(..), TMeta, pattern TypeM)
import qualified Syntax
import Unify.KMeta (HasKindMetas, freshKMeta, solveKMetas)
import Unify.Kind (unifyKind)
import Unify.TMeta (HasTypeMetas)

class HasDatatypeFields s where
  datatypeFields :: Lens' s (Map Text IR.Fields)

class HasDatatypeCtors s where
  datatypeCtors :: Lens' s (Map Text IR.Constructor)

getConstructor ::
  ( MonadState s m, HasDatatypeCtors s
  , MonadError TypeError m
  ) =>
  Span ->
  Text ->
  m IR.Constructor
getConstructor sp ctorName = do
  m_ctor <- uses datatypeCtors $ Map.lookup ctorName
  case m_ctor of
    Nothing -> throwError $ CtorNotInScope sp
    Just ctor -> pure ctor

getFieldType ::
  ( MonadState s m, HasDatatypeFields s
  , MonadError TypeError m
  ) =>
  Span ->
  Text ->
  IR.Projection ->
  m (Maybe (Type (Var Index Void)))
getFieldType sp tyName prj = do
  m_fs <- uses datatypeFields $ Map.lookup tyName
  case m_fs of
    Nothing -> throwError $ TNotInScope sp
    Just fs ->
      pure $ case prj of
        IR.Numeric ix ->
          case fs of
            IR.Unnamed fs' -> Just $ fs' Vector.! fromIntegral ix
            _ -> Nothing
        IR.Field n ->
          case fs of
            IR.Named fs' -> Map.lookup n fs'
            _ -> Nothing

makeSizeTerm ::
  forall s m.
  ( MonadState (s (Var Index Void)) m
  , FilterTypes s
  , HasTypeMetas s
  , forall x. HasKindMetas (s x)
  , forall x. HasSizeMetas (s x)
  , forall x. HasGlobalTheory (s x)
  , MonadError TypeError m
  ) =>
  Map Text Kind ->
  Vector Text ->
  Vector Kind ->
  Map (Constraint (Var Index Void)) SMeta ->
  Vector (Type (Var Index Void)) ->
  m (Set SMeta, Size (Either SMeta Void))
makeSizeTerm kindScope paramNames paramKinds assumedConstraints argTypes = do
  global <- use globalTheory
  let
    theory :: Theory (Either TMeta (Var Index Void))
    theory =
      Theory
      { _thGlobal = global
      , _thLocal = Map.mapKeys (fmap Right) assumedConstraints
      }
  foldlM
    (\(usedSizeMetas, sz) a -> do
       sz' <- typeSizeTerm theory a
       pure (usedSizeMetas <> foldMap (either Set.singleton absurd) sz', plusSize sz sz')
    )
    (mempty, Word 0)
    argTypes
  where
    typeSizeTerm ::
      Theory (Either TMeta (Var Index Void)) ->
      Type (Var Index Void) ->
      m (Size (Either SMeta Void))
    typeSizeTerm theory t = do
      placeholder <- freshSMeta
      (_assumes, subs) <-
        solve
          kindScope
          (Syntax.varSpan Syntax.indexSpan Syntax.voidSpan)
          (unvar (Right . (paramNames Vector.!) . getIndex) absurd)
          (unvar ((paramKinds Vector.!) . getIndex) absurd)
          theory
          [(placeholder, CSized $ Right <$> t)]
      pure $ findSMeta subs placeholder

-- | Given some assumptions and an instance head, construct an axiom type
makeSizeConstraint ::
  Vector Kind ->
  Vector (Constraint (Var Index Void)) ->
  Type (Var Index Void) ->
  Constraint Void
makeSizeConstraint paramKinds as =
  validation (error . ("makeSizeConstraint: un-abstracted bound variable: " <>) . show) id .
  traverse (unvar (Failure . Set.singleton . getIndex) absurd) .
  go mempty (Vector.toList as)
  where
    indices :: Vector Int
    indices = [0..length paramKinds-1]

    -- attempt to abstract over the provided index not present in the set.
    -- if no abstraction was done, returns a Nothing.
    abstractVar ::
      Int ->
      Constraint (Var Index Void) ->
      Maybe (Constraint (Var () (Var Index Void)))
    abstractVar n c =
      let
        (res, abstracted) =
          runWriter $ do
          traverse
            (unvar
              (\n' -> if n == getIndex n' then B () <$ tell (Any True) else pure . F $ B n')
              absurd
            )
            c
      in
        if getAny abstracted
        then Just res
        else Nothing

    abstractVars ::
      Set Int ->
      Constraint (Var Index Void) ->
      Constraint (Var Index Void)
    abstractVars ns c =
      let
        toAbstractOver = Vector.filter (`Set.notMember` ns) indices
      in
        foldr
          (\n rest -> do
             case abstractVar n rest of
               Nothing ->
                 rest
               Just rest' ->
                 CForall Nothing (paramKinds Vector.! n) rest'
          )
          c
          toAbstractOver

    -- the aim of this function is to insert foralls as 'deeply' as possible
    -- e.g. `forall a. C a => forall b. C b => C (f a b)` instead of `forall a b. C a => C b => C (f a b)`
    go ::
      Set Int -> -- free variables that we've seen so far
      [Constraint (Var Index Void)] ->
      Type (Var Index Void) ->
      Constraint (Var Index Void)
    go !freeVars assumes hd =
      case assumes of
        [] ->
          abstractVars freeVars $
          CSized hd
        a:rest ->
          let
            hd' =
              CImplies a $
              go (freeVars <> foldMap (unvar (Set.singleton . getIndex) absurd) a) rest hd
          in
            abstractVars freeVars hd'

-- | Check that an ADT is well formed, and return its
-- * constructor declarations
-- * kind
-- * axiom type
-- * sizeterm
checkADT ::
  forall s m.
  ( MonadState (s (Var Index Void)) m
  , FilterTypes s
  , HasTypeMetas s
  , forall x. HasKindMetas (s x)
  , forall x. HasSizeMetas (s x)
  , forall x. HasGlobalTheory (s x)
  , MonadError TypeError m
  ) =>
  Map Text Kind ->
  Text -> -- name
  Vector Text -> -- type parameters
  Syntax.Ctors (Var Index Void) -> -- constructors
  m (IR.Datatype, Kind, Constraint Void, Size Void)
checkADT kScope datatypeName paramNames ctors = do
  datatypeKind <- KVar <$> freshKMeta
  paramMetas <- Vector.replicateM (Vector.length paramNames) freshKMeta

  let kindScope = Map.insert datatypeName datatypeKind kScope
  adtKinds kindScope paramMetas ctors

  ks <- traverse (solveKMetas . KVar) paramMetas
  let datatypeKind' = foldr KArr KType ks
  unifyKind {- TODO -} Unknown datatypeKind' datatypeKind
  datatypeKind'' <-
    substKMeta (const KType) <$>
    solveKMetas datatypeKind'

  sizeMetas <- Vector.replicateM (Vector.length paramNames) freshSMeta
  paramKinds <- traverse (fmap (substKMeta $ const KType) . solveKMetas . KVar) paramMetas
  let
    assumedConstraintsFwd :: Map (Constraint (Var Index Void)) SMeta
    assumedConstraintsBwd :: Map SMeta (Constraint (Var Index Void))
    (assumedConstraintsFwd, assumedConstraintsBwd) =
      Vector.ifoldl'
        (\(accFwd, accBwd) ix s ->
           let
             k = paramKinds Vector.! ix
             c = unvar (\() -> B $ Index {- TODO -} Unknown ix) F <$> sizeConstraintFor k
           in
             ( Map.insert c s accFwd
             , Map.insert s c accBwd
             )
        )
        (mempty, mempty)
        sizeMetas

  (usedSizeMetas, sz) <-
    adtSizeTerm
      kindScope
      paramKinds
      assumedConstraintsFwd
      0
      mempty
      (Word 0)
      ctors

  let
    usedConstraints :: Vector (Constraint (Var Index Void))
    usedConstraints =
      Vector.map (assumedConstraintsBwd Map.!) $
      Vector.filter (`Set.member` usedSizeMetas) sizeMetas

  let
    m_sz' =
      traverse
        (either (const Nothing) Just)
        (foldr
           (\s -> Lam . abstract (either (guard . (s ==)) (const Nothing)))
           sz
           usedSizeMetas
        )
  case m_sz' of
    Nothing -> error "failed to abstract over all SMetas"
    Just sz' ->
      let
        namedParamKinds = Vector.zip paramNames paramKinds
        datatype =
          case Syntax.ctorsToList ctors of
            [] ->
              IR.Empty datatypeName namedParamKinds
            [(_, ctys)] ->
              IR.Struct datatypeName namedParamKinds ((,) Nothing <$> ctys)
            cs ->
              IR.Enum datatypeName namedParamKinds ((fmap.fmap) ((,) Nothing) <$> Vector.fromList cs)
      in
        pure
          ( datatype
          , IR.substKMeta (const KType) datatypeKind''
          , makeSizeConstraint paramKinds usedConstraints fullyApplied
          , sz'
          )
  where
    fullyApplied :: Type (Var Index Void)
    fullyApplied =
      Vector.foldl
        (\acc ix -> TApp {- TODO -} Unknown acc (TVar . B $ Index {- TODO -} Unknown ix))
        (TName {- TODO -} Unknown datatypeName)
        [0..length paramNames - 1]

    adtKinds ::
      Map Text Kind ->
      Vector KMeta ->
      Syntax.Ctors (Var Index Void) -> -- constructors
      m ()
    adtKinds kindScope paramMetas c =
      case c of
        Syntax.End -> pure ()
        Syntax.Ctor _ctorName ctorArgs ctorRest -> do
          let paramKinds = KVar <$> paramMetas
          traverse_
            (\ty ->
                checkKind
                  kindScope
                  (Syntax.varSpan Syntax.indexSpan Syntax.voidSpan)
                  (unvar ((paramKinds Vector.!) . getIndex) absurd)
                  (TypeM $ Right <$> ty)
                  KType
            )
            ctorArgs
          adtKinds kindScope paramMetas ctorRest

    adtSizeTerm ::
      Map Text Kind ->
      Vector Kind ->
      Map (Constraint (Var Index Void)) SMeta ->
      Int ->
      Set SMeta ->
      Size (Either SMeta Void) ->
      Syntax.Ctors (Var Index Void) -> -- constructors
      m (Set SMeta, Size (Either SMeta Void))
    adtSizeTerm kindScope paramKinds assumedConstraints !ctorCount !usedConstraints sz c =
      case c of
        Syntax.End ->
          pure $!
          if ctorCount > 1
          then (usedConstraints, plusSize (Word 1) sz) -- 1 byte tag
          else (usedConstraints, sz)
        Syntax.Ctor _ctorName ctorArgs ctorRest -> do
          traverse_
            (\ty ->
                checkKind
                  kindScope
                  (Syntax.varSpan Syntax.indexSpan Syntax.voidSpan)
                  (unvar ((paramKinds Vector.!) . getIndex) absurd)
                  (TypeM $ Right <$> ty)
                  KType
            )
            ctorArgs

          (usedConstraints', sz') <- makeSizeTerm kindScope paramNames paramKinds assumedConstraints ctorArgs
          adtSizeTerm
            kindScope
            paramKinds
            assumedConstraints
            (ctorCount+1)
            (usedConstraints <> usedConstraints')
            (maxSize sz sz')
            ctorRest
