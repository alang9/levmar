{-# LANGUAGE CPP
           , NoImplicitPrelude
           , UnicodeSyntax
           , ScopedTypeVariables
           , DeriveDataTypeable
  #-}

--------------------------------------------------------------------------------
-- |
-- Module:     Numeric.LevMar
-- Copyright:  (c) 2009 - 2010 Roel van Dijk & Bas van Dijk
-- License:    BSD-style (see the file LICENSE)
-- Maintainer: Roel van Dijk <vandijk.roel@gmail.com>
--             Bas van Dijk <v.dijk.bas@gmail.com>
-- Stability:  Experimental
--
-- For additional documentation see the documentation of the levmar C
-- library which this library is based on:
-- <http://www.ics.forth.gr/~lourakis/levmar/>
--
--------------------------------------------------------------------------------

module Numeric.LevMar
    ( -- * Model & Jacobian.
      Model
    , Jacobian

      -- * Levenberg-Marquardt algorithm.
    , LevMarable(levmar)

      -- * Minimization options.
    , Options(..)
    , defaultOpts

      -- * Constraints
    , Constraints(..)
    , noConstraints
    , LinearConstraints

      -- * Output
    , Info(..)
    , StopReason(..)
    , CovarMatrix

    , LevMarError(..)
    ) where


-------------------------------------------------------------------------------
-- Imports
-------------------------------------------------------------------------------

-- from base:
import Control.Monad.Instances -- for 'instance Functor (Either a)'
import Control.Exception     ( Exception )
import Data.Typeable         ( Typeable )
import Data.Either           ( Either(Left, Right) )
import Data.Function         ( ($) )
import Data.List             ( lookup, map )
import Data.Maybe            ( Maybe(Nothing, Just)
                             , isJust, fromJust, fromMaybe
                             )
import Data.Ord              ( (<) )
import Foreign.Marshal.Array ( allocaArray, withArray
                             , peekArray, copyArray
                             )
import Foreign.Ptr           ( Ptr, nullPtr )
import Foreign.ForeignPtr    ( newForeignPtr_, mallocForeignPtrArray
                             , withForeignPtr
                             )
import Foreign.Storable      ( Storable )
import Foreign.C.Types       ( CInt )
import Prelude               ( Enum, Fractional, Real, RealFrac
                             , Integer, Float, Double
                             , fromIntegral, realToFrac, toEnum
                             , (-), error, floor
                             )
import System.IO             ( IO )
import System.IO.Unsafe      ( unsafePerformIO )
import Text.Read             ( Read )
import Text.Show             ( Show )

#if __GLASGOW_HASKELL__ < 700
import Prelude               ( fromInteger )
#endif

-- from base-unicode-symbols:
import Data.Bool.Unicode     ( (∧), (∨) )
import Data.Eq.Unicode       ( (≢) )
import Data.Function.Unicode ( (∘) )
import Prelude.Unicode       ( (⋅) )

-- from hmatrix:
import Data.Packed.Vector ( Vector )
import Data.Packed.Matrix ( Matrix, Element, flatten, rows, reshape )

-- from vector:
import qualified Data.Vector.Storable as VS ( unsafeWith, map, length
                                            , unsafeFromForeignPtr
                                            , length
                                            )

-- from bindings-levmar:
import Bindings.LevMar ( c'LM_INFO_SZ

                       , withModel
                       , withJacobian

                       , c'LM_ERROR
                       , c'LM_ERROR_LAPACK_ERROR
                       , c'LM_ERROR_FAILED_BOX_CHECK
                       , c'LM_ERROR_MEMORY_ALLOCATION_FAILURE
                       , c'LM_ERROR_CONSTRAINT_MATRIX_ROWS_GT_COLS
                       , c'LM_ERROR_CONSTRAINT_MATRIX_NOT_FULL_ROW_RANK
                       , c'LM_ERROR_TOO_FEW_MEASUREMENTS
                       , c'LM_ERROR_SINGULAR_MATRIX
                       , c'LM_ERROR_SUM_OF_SQUARES_NOT_FINITE

                       , c'LM_INIT_MU
                       , c'LM_STOP_THRESH
                       , c'LM_DIFF_DELTA
                       )
import qualified Bindings.LevMar ( Model, Jacobian )

-- from levmar (this package):
import Bindings.LevMar.CurryFriendly ( LevMarDer
                                     , LevMarDif
                                     , LevMarBCDer
                                     , LevMarBCDif
                                     , LevMarLecDer
                                     , LevMarLecDif
                                     , LevMarBLecDer
                                     , LevMarBLecDif
                                     , dlevmar_der,      slevmar_der
                                     , dlevmar_dif,      slevmar_dif
                                     , dlevmar_bc_der,   slevmar_bc_der
                                     , dlevmar_bc_dif,   slevmar_bc_dif
                                     , dlevmar_lec_der,  slevmar_lec_der
                                     , dlevmar_lec_dif,  slevmar_lec_dif
                                     , dlevmar_blec_der, slevmar_blec_der
                                     , dlevmar_blec_dif, slevmar_blec_dif
                                     )


--------------------------------------------------------------------------------
-- Model & Jacobian.
--------------------------------------------------------------------------------

{-| A functional relation describing measurements represented as a function
from a vector of parameters to a vector of expected measurements.

 * Ensure that the length of the parameters vector equals the length of the
   initial parameters vector in 'levmar'.

 * Ensure that the length of the ouput vector equals the length of the samples
   vector in 'levmar'.
-}
type Model r = Vector r → Vector r

{-| The jacobian of the 'Model' function. Expressed as a function from a vector
of parameters to a matrix which for each expected measurement describes
the partial derivatives of the parameters.

See: <http://en.wikipedia.org/wiki/Jacobian_matrix_and_determinant>

 * Ensure that the length of the parameter vector equals the length of the initial
   parameter vector in 'levmar'.

 * Ensure that the output matrix has the dimension @n><m@ where @n@ is the
   number of samples and @m@ is the number of parameters.
-}
type Jacobian r = Vector r → Matrix r


--------------------------------------------------------------------------------
-- Levenberg-Marquardt algorithm.
--------------------------------------------------------------------------------

-- | The Levenberg-Marquardt algorithm is overloaded to work on 'Double' and 'Float'.
class LevMarable r where

    -- | The Levenberg-Marquardt algorithm.
    levmar ∷ Model r            -- ^ Model
           → Maybe (Jacobian r) -- ^ Optional jacobian
           → Vector r           -- ^ Initial parameters
           → Vector r           -- ^ Samples
           → Integer            -- ^ Maximum iterations
           → Options r          -- ^ Minimization options
           → Constraints r      -- ^ Constraints
           → Either LevMarError (Vector r, Info r, CovarMatrix r)

instance LevMarable Float where
    levmar = gen_levmar slevmar_der
                        slevmar_dif
                        slevmar_bc_der
                        slevmar_bc_dif
                        slevmar_lec_der
                        slevmar_lec_dif
                        slevmar_blec_der
                        slevmar_blec_dif

instance LevMarable Double where
    levmar = gen_levmar dlevmar_der
                        dlevmar_dif
                        dlevmar_bc_der
                        dlevmar_bc_dif
                        dlevmar_lec_der
                        dlevmar_lec_dif
                        dlevmar_blec_der
                        dlevmar_blec_dif

{-| @gen_levmar@ takes the low-level C functions as arguments and
executes one of them depending on the optional jacobian and constraints.

Preconditions:

@
  length ys >= length ps

     isJust mLowBs && length (fromJust mLowBs) == length ps
  && isJust mUpBs  && length (fromJust mUpBs)  == length ps

  boxConstrained && (all $ zipWith (<=) (fromJust mLowBs) (fromJust mUpBs))
@
-}
gen_levmar ∷ ∀ cr r.
               ( Storable cr, RealFrac cr
               , Storable r,  Real r, Fractional r, Element r
               )
           ⇒ LevMarDer cr
           → LevMarDif cr
           → LevMarBCDer cr
           → LevMarBCDif cr
           → LevMarLecDer cr
           → LevMarLecDif cr
           → LevMarBLecDer cr
           → LevMarBLecDif cr

           → Model r            -- ^ Model
           → Maybe (Jacobian r) -- ^ Optional jacobian
           → Vector r           -- ^ Initial parameters
           → Vector r           -- ^ Samples
           → Integer            -- ^ Maximum iterations
           → Options r          -- ^ Options
           → Constraints r      -- ^ Constraints
           → Either LevMarError (Vector r, Info r, CovarMatrix r)
gen_levmar f_der
           f_dif
           f_bc_der
           f_bc_dif
           f_lec_der
           f_lec_dif
           f_blec_der
           f_blec_dif
           model mJac ps ys itMax opts (Constraints mLowBs mUpBs mWeights mLinC)
    = unsafePerformIO $ do
        psFP ← mallocForeignPtrArray lenPs
        withForeignPtr psFP $ \psPtr → do
          VS.unsafeWith (VS.map realToFrac ps) $ \psPtrInp →
            copyArray psPtr psPtrInp lenPs
          VS.unsafeWith (VS.map realToFrac ys) $ \ysPtr →
            withArray (map realToFrac $ optsToList opts) $ \optsPtr →
              allocaArray c'LM_INFO_SZ $ \infoPtr → do
                covarFP ← mallocForeignPtrArray covarLen
                withForeignPtr covarFP $ \covarPtr →
                  let cmodel ∷ Bindings.LevMar.Model cr
                      cmodel parPtr hxPtr _ _ _ = do
                        parFP ← newForeignPtr_ parPtr
                        let psV = VS.unsafeFromForeignPtr parFP 0 lenPs
                            vector = VS.map realToFrac $ model $ VS.map realToFrac psV
                        VS.unsafeWith vector $ \p → copyArray hxPtr p (VS.length vector)
                  in withModel cmodel $ \modelPtr → do
                     -- Calling the correct low-level levmar function:
                     let runDif ∷ LevMarDif cr → IO CInt
                         runDif f = f modelPtr
                                      psPtr
                                      ysPtr
                                      (fromIntegral lenPs)
                                      (fromIntegral lenYs)
                                      (fromIntegral itMax)
                                      optsPtr
                                      infoPtr
                                      nullPtr
                                      covarPtr
                                      nullPtr

                     err ← case mJac of
                       Nothing → if boxConstrained
                                 then if linConstrained
                                      then withBoxConstraints
                                               (withLinConstraints $ withWeights runDif)
                                               f_blec_dif
                                      else withBoxConstraints runDif f_bc_dif
                                 else if linConstrained
                                      then withLinConstraints runDif f_lec_dif
                                      else runDif f_dif
                       Just jac →
                         let cjacobian ∷ Bindings.LevMar.Jacobian cr
                             cjacobian parPtr jPtr _ _ _ = do
                               parFP ← newForeignPtr_ parPtr
                               let psV    = VS.unsafeFromForeignPtr parFP 0 lenPs
                                   matrix = jac $ VS.map realToFrac psV
                                   vector = VS.map realToFrac $ flatten matrix
                               VS.unsafeWith vector $ \p →
                                 copyArray jPtr p (VS.length vector)
                         in withJacobian cjacobian $ \jacobPtr →
                           let runDer ∷ LevMarDer cr → IO CInt
                               runDer f = runDif $ f jacobPtr
                           in if boxConstrained
                              then if linConstrained
                                   then withBoxConstraints
                                            (withLinConstraints $ withWeights runDer)
                                            f_blec_der
                                   else withBoxConstraints runDer f_bc_der
                              else if linConstrained
                                   then withLinConstraints runDer f_lec_der
                                   else runDer f_der

                     -- Handling errors:
                     if err < 0
                        -- we don't treat these two as an error
                        ∧ err ≢ c'LM_ERROR_SINGULAR_MATRIX
                        ∧ err ≢ c'LM_ERROR_SUM_OF_SQUARES_NOT_FINITE
                       then return $ Left $ convertLevMarError err
                       else -- Converting results:
                            do info ← peekArray c'LM_INFO_SZ infoPtr
                               return $ Right
                                 ( VS.map realToFrac $
                                     VS.unsafeFromForeignPtr psFP 0 lenPs
                                 , listToInfo info
                                 , reshape lenPs $ VS.map realToFrac $
                                     VS.unsafeFromForeignPtr covarFP 0 covarLen
                                 )
      where
        lenPs          = VS.length ps
        lenYs          = VS.length ys
        covarLen       = lenPs⋅lenPs
        (cMat, rhcVec) = fromJust mLinC

        -- Whether the parameters are constrained by a linear equation.
        linConstrained = isJust mLinC

        -- Whether the parameters are constrained by a bounding box.
        boxConstrained = isJust mLowBs ∨ isJust mUpBs

        withBoxConstraints f g =
            maybeWithArray mLowBs $ \lBsPtr →
              maybeWithArray mUpBs $ \uBsPtr →
                f $ g lBsPtr uBsPtr

        withLinConstraints f g =
            VS.unsafeWith (VS.map realToFrac $ flatten cMat) $ \cMatPtr →
              VS.unsafeWith (VS.map realToFrac rhcVec) $ \rhcVecPtr →
                f ∘ g cMatPtr rhcVecPtr ∘ fromIntegral $ rows cMat

        withWeights f g = maybeWithArray mWeights $ f ∘ g


--------------------------------------------------------------------------------
-- Minimization options.
--------------------------------------------------------------------------------

-- | Minimization options
data Options r =
    Opts { optScaleInitMu      ∷ r -- ^ Scale factor for initial /mu/.
         , optStopNormInfJacTe ∷ r -- ^ Stopping thresholds for @||J^T e||_inf@.
         , optStopNorm2Dp      ∷ r -- ^ Stopping thresholds for @||Dp||_2@.
         , optStopNorm2E       ∷ r -- ^ Stopping thresholds for @||e||_2@.
         , optDelta            ∷ r -- ^ Step used in the difference
                                   -- approximation to the Jacobian. If
                                   -- @optDelta<0@, the Jacobian is approximated
                                   -- with central differences which are more
                                   -- accurate (but slower!)  compared to the
                                   -- forward differences employed by default.
         } deriving (Read, Show)

-- | Default minimization options
defaultOpts ∷ Fractional r ⇒ Options r
defaultOpts = Opts { optScaleInitMu      = c'LM_INIT_MU
                   , optStopNormInfJacTe = c'LM_STOP_THRESH
                   , optStopNorm2Dp      = c'LM_STOP_THRESH
                   , optStopNorm2E       = c'LM_STOP_THRESH
                   , optDelta            = c'LM_DIFF_DELTA
                   }

optsToList ∷ Options r → [r]
optsToList (Opts mu  eps1  eps2  eps3  delta) =
                [mu, eps1, eps2, eps3, delta]


--------------------------------------------------------------------------------
-- Constraints
--------------------------------------------------------------------------------

-- | Ensure that these vectors have the same length as the number of parameters.
data Constraints r = Constraints
    { lowerBounds       ∷ Maybe (Vector r)            -- ^ Optional lower bounds
    , upperBounds       ∷ Maybe (Vector r)            -- ^ Optional upper bounds
    , weights           ∷ Maybe (Vector r)            -- ^ Optional weights
    , linearConstraints ∷ Maybe (LinearConstraints r) -- ^ Optional linear constraints
    }

-- | Linear constraints consisting of a constraints matrix, @k><m@ and
--   a right hand constraints vector, of length @k@ where @m@ is the number of
--   parameters and @k@ is the number of constraints.
type LinearConstraints r = (Matrix r, Vector r)

-- | Constraints where all fields are 'Nothing'.
noConstraints ∷ Constraints r
noConstraints = Constraints Nothing Nothing Nothing Nothing

maybeWithArray ∷ (Real α, Fractional r, Storable r, Storable α)
               ⇒ Maybe (Vector α) → (Ptr r → IO β) → IO β
maybeWithArray Nothing  f = f nullPtr
maybeWithArray (Just v) f = VS.unsafeWith (VS.map realToFrac v) f


--------------------------------------------------------------------------------
-- Output
--------------------------------------------------------------------------------

-- | Information regarding the minimization.
data Info r = Info
  { infNorm2initE      ∷ r          -- ^ @||e||_2@             at initial parameters.
  , infNorm2E          ∷ r          -- ^ @||e||_2@             at estimated parameters.
  , infNormInfJacTe    ∷ r          -- ^ @||J^T e||_inf@       at estimated parameters.
  , infNorm2Dp         ∷ r          -- ^ @||Dp||_2@            at estimated parameters.
  , infMuDivMax        ∷ r          -- ^ @\mu/max[J^T J]_ii ]@ at estimated parameters.
  , infNumIter         ∷ Integer    -- ^ Number of iterations.
  , infStopReason      ∷ StopReason -- ^ Reason for terminating.
  , infNumFuncEvals    ∷ Integer    -- ^ Number of function evaluations.
  , infNumJacobEvals   ∷ Integer    -- ^ Number of jacobian evaluations.
  , infNumLinSysSolved ∷ Integer    -- ^ Number of linear systems solved,
                                    --   i.e. attempts for reducing error.
  } deriving (Read, Show)

listToInfo ∷ (RealFrac cr, Fractional r) ⇒ [cr] → Info r
listToInfo [a,b,c,d,e,f,g,h,i,j] =
    Info { infNorm2initE      = realToFrac a
         , infNorm2E          = realToFrac b
         , infNormInfJacTe    = realToFrac c
         , infNorm2Dp         = realToFrac d
         , infMuDivMax        = realToFrac e
         , infNumIter         = floor f
         , infStopReason      = toEnum $ floor g - 1
         , infNumFuncEvals    = floor h
         , infNumJacobEvals   = floor i
         , infNumLinSysSolved = floor j
         }
listToInfo _ = error "liftToInfo: wrong list length"

-- | Reason for terminating.
data StopReason
  = SmallGradient  -- ^ Stopped because of small gradient @J^T e@.
  | SmallDp        -- ^ Stopped because of small Dp.
  | MaxIterations  -- ^ Stopped because maximum iterations was reached.
  | SingularMatrix -- ^ Stopped because of singular matrix. Restart from current
                   --   estimated parameters with increased 'optScaleInitMu'.
  | SmallestError  -- ^ Stopped because no further error reduction is
                   --   possible. Restart with increased 'optScaleInitMu'.
  | SmallNorm2E    -- ^ Stopped because of small @||e||_2@.
  | InvalidValues  -- ^ Stopped because model function returned invalid values
                   --   (i.e. NaN or Inf). This is a user error.
    deriving (Read, Show, Enum)

-- | Covariance matrix corresponding to LS solution.
type CovarMatrix r = Matrix r


--------------------------------------------------------------------------------
-- Error
--------------------------------------------------------------------------------

data LevMarError
    = LevMarError                    -- ^ Generic error (not one of the others)
    | LapackError                    -- ^ A call to a lapack subroutine failed
                                     --   in the underlying C levmar library.
    | FailedBoxCheck                 -- ^ At least one lower bound exceeds the
                                     --   upper one.
    | MemoryAllocationFailure        -- ^ A call to @malloc@ failed in the
                                     --   underlying C levmar library.
    | ConstraintMatrixRowsGtCols     -- ^ The matrix of constraints cannot have
                                     --   more rows than columns.
    | ConstraintMatrixNotFullRowRank -- ^ Constraints matrix is not of full row
                                     --   rank.
    | TooFewMeasurements             -- ^ Cannot solve a problem with fewer
                                     --   measurements than unknowns.  In case
                                     --   linear constraints are provided, this
                                     --   error is also returned when the number
                                     --   of measurements is smaller than the
                                     --   number of unknowns minus the number of
                                     --   equality constraints.
      deriving (Show, Typeable)

-- Handy in case you want to thow a LevMarError as an exception:
instance Exception LevMarError

levmarCErrorToLevMarError ∷ [(CInt, LevMarError)]
levmarCErrorToLevMarError =
    [ (c'LM_ERROR,                                     LevMarError)
    , (c'LM_ERROR_LAPACK_ERROR,                        LapackError)
  --, (c'LM_ERROR_NO_JACOBIAN,                         can never happen)
  --, (c'LM_ERROR_NO_BOX_CONSTRAINTS,                  can never happen)
    , (c'LM_ERROR_FAILED_BOX_CHECK,                    FailedBoxCheck)
    , (c'LM_ERROR_MEMORY_ALLOCATION_FAILURE,           MemoryAllocationFailure)
    , (c'LM_ERROR_CONSTRAINT_MATRIX_ROWS_GT_COLS,      ConstraintMatrixRowsGtCols)
    , (c'LM_ERROR_CONSTRAINT_MATRIX_NOT_FULL_ROW_RANK, ConstraintMatrixNotFullRowRank)
    , (c'LM_ERROR_TOO_FEW_MEASUREMENTS,                TooFewMeasurements)
  --, (c'LM_ERROR_SINGULAR_MATRIX,                     we don't treat this as an error)
  --, (c'LM_ERROR_SUM_OF_SQUARES_NOT_FINITE,           we don't treat this as an error)
    ]

convertLevMarError ∷ CInt → LevMarError
convertLevMarError err = fromMaybe (error "Unknown levmar error") $
                         lookup err levmarCErrorToLevMarError


-- The End ---------------------------------------------------------------------