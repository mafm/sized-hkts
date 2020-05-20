{-# language OverloadedLists, OverloadedStrings #-}
{-# language PatternSynonyms #-}
{-# language TypeApplications #-}
module Main where

import Bound.Scope (toScope)
import Bound.Var (Var(..))
import Control.Monad.Except (runExceptT)
import Control.Monad.State (evalState)
import Control.Monad.Trans.Maybe (runMaybeT)
import qualified Data.Map as Map
import Data.Maybe (fromMaybe)
import Data.Void (Void, absurd)
import Test.Hspec

import Entailment
  ( EntailError(..), Size, SMeta(..), Theory(..)
  , composeSSubs, emptyEntailState, freshSMeta, simplify, solve
  )
import qualified Entailment as Size (Size(..), pattern Var)
import IR (Constraint(..), Kind(..))
import Syntax (Type(..), WordSize(..))
import Typecheck (TMeta, sizeConstraintFor)

main :: IO ()
main =
  hspec $ do
    describe "sizeConstraintFor" $ do
      it "*" $
        sizeConstraintFor @Void 0 KType `shouldBe` CSized (TVar $ B ())
      it "* -> *" $
        sizeConstraintFor @Void 0 (KArr KType KType) `shouldBe`
        CForall "t0" KType
          (CImplies
             (CSized (TVar $ B ()))
             (CSized $
              TApp
                (TVar $ F $ B ())
                (TVar $ B ())
             )
          )
      it "* -> * -> *" $
        sizeConstraintFor @Void 0 (KArr KType $ KArr KType KType) `shouldBe`
        CForall "t0" KType
          (CImplies
             (CSized $ TVar $ B ())
             (CForall "t1" KType . CImplies (CSized $ TVar $ B ()) $
              CSized $
              TApp
                (TApp
                   (TVar $ F $ F $ B ())
                   (TVar $ F $ B ())
                )
                (TVar $ B ())
             )
          )
      it "* -> (* -> *) -> *" $
        sizeConstraintFor @Void 0 (KArr KType $ KArr (KArr KType KType) KType) `shouldBe`
        -- forall x : Type
        CForall "t0" KType
          -- Sized x =>
          (CImplies (CSized $ TVar $ B ()) $
           -- forall y : Type -> Type.
           CForall "t1" (KArr KType KType) .
           -- (forall z : Type. Sized z => Sized (y z)) =>
           CImplies
             (CForall "t2" KType $
              CImplies
                (CSized $ TVar $ B ())
                (CSized $ TApp (TVar $ F $ B ()) (TVar $ B ()))
             ) $
           -- Sized (#0 x y)
           CSized $
           TApp
             (TApp
               (TVar $ F $ F $ B ())
               (TVar $ F $ B ())
             )
             (TVar $ B ())
          )
    describe "entailment" $ do
      it "simplify { (64, Sized U64) } (d0 : Sized U64) ==> [d0 := 64]" $ do
        let
          theory :: Theory (Either TMeta Void)
          theory =
            Theory
            { thGlobal =
              [ (CSized $ TUInt S64, Size.Word 64)
              ]
            , thLocal = mempty
            }
          e_res = flip evalState emptyEntailState . runExceptT $ do
            m <- freshSMeta
            (,) m <$> simplify absurd absurd theory (m, CSized $ TUInt S64)
        case e_res of
          Left{} -> expectationFailure "expected success, got error"
          Right (d0, res) -> res `shouldBe` ([], [(d0, Size.Word 64 :: Size (Either SMeta Void))])
      it "solve $ simplify { (64, Sized U64), (\\x -> x + x, forall a. Sized a => Sized (Pair a)) } (d0 : Sized (Pair U64)) ==> [d0 := 128]" $ do
        let
          theory :: Theory (Either TMeta Void)
          theory =
            Theory
            { thGlobal =
              [ (CSized $ TUInt S64, Size.Word 64)
              , ( CForall "a" KType $
                  CImplies
                    (CSized $ TVar $ B ())
                    (CSized $ TApp (TName "Pair") (TVar $ B ()))
                , Size.Lam . toScope $ Size.Plus (Size.Var $ B ()) (Size.Var $ B ())
                )
              ]
            , thLocal = mempty
            }
          e_res = flip evalState emptyEntailState . runExceptT $ do
            m <- freshSMeta
            (assumes, sols) <-
              fmap (fromMaybe ([], mempty)) . runMaybeT $
              simplify absurd absurd theory (m, CSized $ TApp (TName "Pair") (TUInt S64))
            (assumes', sols') <- solve absurd absurd theory assumes
            pure (m, (assumes', composeSSubs sols' sols))
        case e_res of
          Left err -> expectationFailure $ "expected success, got error: " <> show err
          Right (d0, (assumes, sols)) ->
            Map.lookup d0 sols `shouldBe` Just (Size.Word 128 :: Size (Either SMeta Void))
      it "solve $ simplify { (\\x -> x + x, forall a. Sized a => Sized (Pair a)) } (d0 : Sized (Pair U64)) ==> cannot deduce  Sized U64" $ do
        let
          theory :: Theory (Either TMeta Void)
          theory =
            Theory
            { thGlobal =
              [ ( CForall "a" KType $
                  CImplies
                    (CSized $ TVar $ B ())
                    (CSized $ TApp (TName "Pair") (TVar $ B ()))
                , Size.Lam . toScope $ Size.Plus (Size.Var $ B ()) (Size.Var $ B ())
                )
              ]
            , thLocal = mempty
            }
          e_res = flip evalState emptyEntailState . runExceptT $ do
            m <- freshSMeta
            (assumes, sols) <-
              fmap (fromMaybe ([], mempty)) . runMaybeT $
              simplify absurd absurd theory (m, CSized $ TApp (TName "Pair") (TUInt S64))
            (assumes', sols') <- solve absurd absurd theory assumes
            pure (m, (assumes', composeSSubs sols' sols))
        case e_res of
          Left err -> err `shouldBe` CouldNotDeduce (CSized $ TUInt S64)
          Right{} -> expectationFailure "expected failure, got success"
      it "solve $ simplify { (\\x -> x + x, forall x. Sized x => Sized (Pair x)) } (d0 : forall a. Sized (Pair a) => Sized a) ==> cannot deduce   Sized a" $ do
        let
          theory :: Theory (Either TMeta Void)
          theory =
            Theory
            { thGlobal =
              [ ( CForall "x" KType $
                  CImplies
                    (CSized $ TVar $ B ())
                    (CSized $ TApp (TName "Pair") (TVar $ B ()))
                , Size.Lam . toScope $ Size.Plus (Size.Var $ B ()) (Size.Var $ B ())
                )
              ]
            , thLocal = mempty
            }
          e_res = flip evalState emptyEntailState . runExceptT $ do
            m <- freshSMeta
            (assumes, sols) <-
              fmap (fromMaybe ([], mempty)) . runMaybeT $
              simplify absurd absurd theory
                ( m
                , CForall "a" KType $
                  CImplies
                    (CSized $ TApp (TName "Pair") (TVar $ B ()))
                    (CSized $ TVar $ B ())
                )
            (assumes', sols') <- solve @_ @_ @Void absurd absurd theory assumes
            pure (m, (assumes', composeSSubs sols' sols))
        case e_res of
          Left err -> err `shouldBe` CouldNotDeduce (CSized $ TVar $ Right "a")
          Right res -> expectationFailure $ "expected error, got success: " <> show res
