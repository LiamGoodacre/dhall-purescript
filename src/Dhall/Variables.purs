module Dhall.Variables where

import Prelude

import Data.Const (Const(..))
import Data.Foldable (class Foldable, fold)
import Data.Functor.Variant (VariantF)
import Data.Functor.Variant as VariantF
import Data.HeytingAlgebra (ff)
import Data.Maybe (Maybe(..))
import Data.Monoid.Disj (Disj(..))
import Data.Newtype (over, unwrap)
import Data.These (These(..))
import Data.Tuple (Tuple(..), fst)
import Data.Variant (Variant)
import Data.Variant as Variant
import Dhall.Core.AST (BindingBody(..), CONST, Expr, LetF(..), S_, Var(..), Variable, _S, mkVar)
import Dhall.Core.AST as AST
import Dhall.Core.AST.Operations.Transformations (ConsNodeOps, GenericExprAlgebraVT, NodeOps, elim1, runAlgebraExpr, runOverCases)
import Matryoshka (Algebra, cata)
import Type.Row (type (+))
import Type.Row as R

-- | `shift` is used by both normalization and type-checking to avoid variable
-- | capture by shifting variable indices
-- | For example, suppose that you were to normalize the following expression:
-- | ```dhall
-- | λ(a : Type) → λ(x : a) → (λ(y : a) → λ(x : a) → y) x
-- | ```
-- |
-- | If you were to substitute `y` with `x` without shifting any variable
-- | indices, then you would get the following incorrect result:
-- | ```dhall
-- | λ(a : Type) → λ(x : a) → λ(x : a) → x  -- Incorrect normalized form
-- | ```
-- |
-- | In order to substitute `x` in place of `y` we need to `shift` `x` by `1` in
-- | order to avoid being misinterpreted as the `x` bound by the innermost
-- | lambda.  If we perform that `shift` then we get the correct result:
-- | ```dhall
-- | λ(a : Type) → λ(x : a) → λ(x : a) → x@1
-- | ```
-- |
-- | As a more worked example, suppose that you were to normalize the following
-- | expression:
-- | ```dhall
-- |     λ(a : Type)
-- | →   λ(f : a → a → a)
-- | →   λ(x : a)
-- | →   λ(x : a)
-- | →   (λ(x : a) → f x x@1) x@1
-- | ```
-- |
-- | The correct normalized result would be:
-- | ```dhall
-- |     λ(a : Type)
-- | →   λ(f : a → a → a)
-- | →   λ(x : a)
-- | →   λ(x : a)
-- | →   f x@1 x
-- | ```
-- |
-- | The above example illustrates how we need to both increase and decrease
-- | variable indices as part of substitution:
-- | * We need to increase the index of the outer `x@1` to `x@2` before we
-- |   substitute it into the body of the innermost lambda expression in order
-- |   to avoid variable capture.  This substitution changes the body of the
-- |   lambda expression to `f x@2 x@1`
-- | * We then remove the innermost lambda and therefore decrease the indices of
-- |   both `x`s in `f x@2 x@1` to `f x@1 x` in order to reflect that one
-- |   less `x` variable is now bound within that scope
-- | Formally, `shift d (V x n) e` modifies the expression `e` by adding `d` to
-- | the indices of all variables named `x` whose indices are greater than
-- | `n + m`, where `m` is the number of bound variables of the same name
-- | within that scope
-- | In practice, `d` is always `1` or `-1` because we either:
-- | * increment variables by `1` to avoid variable capture during substitution
-- | * decrement variables by `1` when deleting lambdas after substitution
-- |
-- | `n` starts off at @0@ when substitution begins and increments every time we
-- | descend into a lambda or let expression that binds a variable of the same
-- | name in order to avoid shifting the bound variables by mistake.
shift :: forall m a. Int -> Var -> Expr m a -> Expr m a
shift d v = runAlgebraExpr (Variant.case_ # shiftAlgG) $
  Variant.inj (_S::S_ "shift") { delta: d, variable: v }

-- | Substitute all occurrences of a variable with an expression
-- | `subst x C B  ~  B[x := C]`
subst :: forall m a. Var -> Expr m a -> Expr m a -> Expr m a
subst v e = runAlgebraExpr (Variant.case_ # shiftSubstAlgG) $
  Variant.inj (_S::S_ "subst") { variable: v, substitution: e }

-- | The usual combination of subst and shift required for proper substitution.
shiftSubstShift :: forall m a. Var -> Expr m a -> Expr m a -> Expr m a
shiftSubstShift v a b = shift (-1) v (subst v (shift 1 v a) b)

shiftSubstShift0 :: forall m a. String ->  Expr m a -> Expr m a -> Expr m a
shiftSubstShift0 v = shiftSubstShift $ AST.V v 0

rename :: forall m a. Var -> Var -> Expr m a -> Expr m a
rename v0 v1 | v0 == v1 = identity
rename v0 v1 = shift (-1) v0 <<< subst v0 (mkVar v1) <<< shift 1 v1

-- | α-normalize an expression by renaming all variables to `"_"` and using
-- | De Bruijn indices to distinguish them
alphaNormalize :: forall m a. Expr m a -> Expr m a
alphaNormalize = runAlgebraExpr (Variant.case_ # alphaNormalizeAlgG) $
  Variant.inj (_S::S_ "alphaNormalize") {}

-- | Detect if the given variable is free within the given expression
freeIn :: forall m a. Foldable m => Var -> Expr m a -> Disj Boolean
freeIn = flip $ cata $ freeInAlg <<< unwrap

-----------------------------------------------------------------
-- Helpers to track how certain functors affect variable scope --
-----------------------------------------------------------------

type Intro node = Tuple String (These node node)
-- BindingBody binds in its last argument
trackIntroBindingBody :: forall a b.
  (Maybe (Intro a) -> a -> b) -> BindingBody a -> BindingBody b
trackIntroBindingBody next (BindingBody name ty body) = BindingBody name
  do next Nothing ty
  do next (Just (Tuple name (That ty))) body

-- LetF binds in its last argument
trackIntroLetF :: forall a b.
  (Maybe (Intro a) -> a -> b) -> LetF a -> LetF b
trackIntroLetF next (LetF name mty value body) = LetF name
  do next Nothing <$> mty
  do next Nothing value
  let
    valty = case mty of
      Nothing -> This value
      Just ty -> Both value ty
  in next (Just (Tuple name valty)) body

trackIntroVar :: forall a. Maybe (Intro a) -> Maybe String
trackIntroVar = map fst

trackVar :: Var -> Maybe String -> Var
trackVar v@(V x n) = case _ of
  Just x' | x == x' -> V x (n+1)
  _ -> v

trackIntro :: forall m v a b. (Maybe (Intro a) -> a -> b) ->
  VariantF (Variable m + v) a -> VariantF (Variable m + v) b
trackIntro next = VariantF.mapSomeExpand
  (trackIntroCases next)
  (next Nothing)

trackIntroCases :: forall a b. (Maybe (Intro a) -> a -> b) ->
  { "Var" :: Const Var a -> Const Var b
  , "Lam" :: BindingBody a -> BindingBody b
  , "Pi"  :: BindingBody a -> BindingBody b
  , "Let" :: LetF a -> LetF b
  }
trackIntroCases next =
  { "Var": over Const identity
  , "Lam": trackIntroBindingBody next
  , "Pi": trackIntroBindingBody next
  , "Let": trackIntroLetF next
  }

-- A simple algebra for `freeIn`. Will work with anything that is
-- vaguely like `Expr`.
freeInAlg ::
  forall m v rl.
    R.RowToList (Variable m + v) rl =>
    VariantF.FoldableVFRL rl (Variable m + v) =>
  Algebra (VariantF (Variable m + v)) (Var -> Disj Boolean)
freeInAlg layer v | layer # VariantF.on (_S::S_ "Var") (eq (Const v)) ff = Disj true
freeInAlg layer v = layer # trackIntro ((#) <<< trackVar v <<< trackIntroVar) >>> fold

-- Generic Algebra for shifting variable references.
type ShiftAlg node v = ( shift :: { delta :: Int, variable :: Var } | v )
shiftAlgG :: forall m. GenericExprAlgebraVT NodeOps (Variable m) ShiftAlg
shiftAlgG = elim1 (_S::S_ "shift")
  \i@{ delta, variable: v@(V x n) } node ->
    let recur = node.recurse <<< Variant.inj (_S::S_ "shift") <<< { delta, variable: _ } in
    { "Var": over Const \(V x' n') ->
      let n'' = if x == x' && n <= n' then n' + delta else n'
      in V x' n''
    , "Lam": trackIntroBindingBody (recur <<< trackVar v <<< trackIntroVar)
    , "Pi": trackIntroBindingBody (recur <<< trackVar v <<< trackIntroVar)
    , "Let": trackIntroLetF (recur <<< trackVar v <<< trackIntroVar)
    }

-- Generic Algebra for substituting variable references.
-- (Note how the input type references `node`.)
type SubstAlg node v = ( subst :: { variable :: Var, substitution :: node } | v )
type ShiftSubstAlg node v = ShiftAlg node + SubstAlg node + v
shiftSubstAlgG :: forall m. GenericExprAlgebraVT NodeOps (Variable m) ShiftSubstAlg
shiftSubstAlgG rest = rest # shiftAlgG <<< Variant.on (_S::S_ "subst")
  \i@{ variable: variable, substitution } node ->
  let
    isTarget = node.unlayer >>> VariantF.on (_S::S_ "Var")
      (eq (Const variable)) ff
    substIfTarget c = isTarget >>= if _ then pure substitution else c
    subst1 v' s' = node.recurse <<< Variant.inj (_S::S_ "subst") $ { variable: v', substitution: s' }
    shift1 name = node.recurse <<< Variant.inj (_S::S_ "shift") $ { delta: 1, variable: V name 0 }
    -- If a variable is being introduced, shift it _in_ in the substitution
    addShift1 = flip case _ of
      Nothing -> identity
      Just name -> shift1 name
    -- And track if the variable being searched for should be changed as well
    next = subst1 <$> trackVar variable <*> addShift1 substitution
  in
    isTarget >>= if _
      then pure substitution
      else runOverCases node.overlayer (next Nothing) $
        trackIntroCases (next <<< trackIntroVar)

-- The Generic Algebra Command for renaming (which consists of shifting and
-- substitution).
-- TODO: is this fusion okay? is this even fusion? could it be more fused?
doRenameAlgG :: forall node ops v r. Var -> Var ->
  { layer :: VariantF ( "Var" :: CONST Var | r ) node -> node
  , recurse :: Variant (ShiftSubstAlg node v) -> node -> node
  | ops
  } ->
  node -> node
doRenameAlgG v0 v1 _ | v0 == v1 = identity
doRenameAlgG v0 v1 node = identity
  >>> node.recurse (Variant.inj (_S::S_ "shift") { delta: 1, variable: v1 })
  >>> node.recurse (Variant.inj (_S::S_ "subst") { variable: v0, substitution: newV })
  >>> node.recurse (Variant.inj (_S::S_ "shift") { delta: -1, variable: v0 })
  where
    newV = node.layer $ VariantF.inj (_S::S_ "Var") (Const v1)

-- The Generic Algebra to rename all bound variables to `_`.
type AlphaNormalizeAlg node v = ShiftSubstAlg node + ( "alphaNormalize" :: {} | v )
alphaNormalizeAlgG :: forall m. GenericExprAlgebraVT ConsNodeOps (Variable m) AlphaNormalizeAlg
alphaNormalizeAlgG rest = rest # shiftSubstAlgG <<< elim1 (_S::S_ "alphaNormalize") \_ node ->
  let
    norm = node.recurse <<< Variant.inj (_S::S_ "alphaNormalize") $ {}
    renam Nothing = norm
    renam (Just "_") = norm
    renam (Just x) = norm <<< doRenameAlgG (V x 0) (V "_" 0) node
  in
  trackIntroCases (renam <<< trackIntroVar)
