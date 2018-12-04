module Dhall.Normalize where

import Prelude

import Control.Apply (lift2, lift3)
import Control.Comonad (extract)
import Control.Plus (empty)
import Data.Array (foldr)
import Data.Array as Array
import Data.Function (on)
import Data.Functor.App as AppF
import Data.Functor.Compose (Compose(..))
import Data.Functor.Product (Product(..))
import Data.Functor.Variant as VariantF
import Data.FunctorWithIndex (mapWithIndex)
import Data.Identity (Identity(..))
import Data.Int (even, toNumber)
import Data.Lazy (Lazy, defer)
import Data.Lens as Lens
import Data.Lens.Iso.Newtype (_Newtype)
import Data.Maybe (Maybe(..), fromMaybe, isJust)
import Data.Maybe.First (First)
import Data.Monoid.Conj (Conj(..))
import Data.Monoid.Disj (Disj(..))
import Data.Natural (intToNat, natToInt, (+-))
import Data.Newtype (class Newtype, un, unwrap)
import Data.These (These(..))
import Data.Traversable (sequence)
import Data.Tuple (Tuple(..))
import Dhall.Core.AST (Expr, projectW)
import Dhall.Core.AST as AST
import Dhall.Core.AST.Operations (rewriteBottomUpA')
import Dhall.Core.AST.Types.Basics (S_, _S)
import Dhall.Core.StrMapIsh (class StrMapIsh)
import Dhall.Core.StrMapIsh as IOSM
import Dhall.Core.StrMapIsh as StrMapIsh
import Dhall.Normalize.Apps (Apps, apps, noapp, noapplit, noapplit', (~))
import Dhall.Variables as Variables
import Matryoshka (class Recursive, project)
import Unsafe.Coerce (unsafeCoerce)

-- | Reduce an expression to its normal form, performing beta reduction
-- | `normalize` does not type-check the expression.  You may want to type-check
-- | expressions before normalizing them since normalization can convert an
-- | ill-typed expression into a well-typed expression.
-- | However, `normalize` will not fail if the expression is ill-typed and will
-- | leave ill-typed sub-expressions unevaluated.
normalize :: forall m a. StrMapIsh m => Eq a => Expr m a -> Expr m a
normalize = normalizeWith mempty

-- | This function is used to determine whether folds like `Natural/fold` or
-- | `List/fold` should be lazy or strict in their accumulator based on the type
-- | of the accumulator
-- |
-- | If this function returns `True`, then they will be strict in their
-- | accumulator since we can guarantee an upper bound on the amount of work to
-- | normalize the accumulator on each step of the loop.  If this function
-- | returns `False` then they will be lazy in their accumulator and only
-- | normalize the final result at the end of the fold
boundedType :: forall m a. Expr m a -> Boolean
boundedType _ = false

-- | Use this to wrap you embedded functions (see `normalizeWith`) to make them
-- | polymorphic enough to be used.
newtype Normalizer m a = Normalizer (Apps m a -> Maybe (Unit -> Expr m a))
derive instance newtypeNormalizer :: Newtype (Normalizer m a) _
-- not Alt, because it is not a covariant functor
instance semigroupNormalizer :: Semigroup (Normalizer m a) where
  append (Normalizer n) (Normalizer m) = Normalizer \as ->
    case n as of
      Just r -> Just r
      Nothing -> m as
instance monoidNormalizer :: Monoid (Normalizer m a) where
  mempty = Normalizer \_ -> Nothing

type Preview' a b = Lens.Fold (First b) a a b b

{-| Reduce an expression to its normal form, performing beta reduction and applying
    any custom definitions.
    `normalizeWith` is designed to be used with function `typeWith`. The `typeWith`
    function allows typing of Dhall functions in a custom typing context whereas
    `normalizeWith` allows evaluating Dhall expressions in a custom context.
    To be more precise `normalizeWith` applies the given normalizer when it finds an
    application term that it cannot reduce by other means.
    Note that the context used in normalization will determine the properties of normalization.
    That is, if the functions in custom context are not total then the Dhall language, evaluated
    with those functions is not total either.
-}
normalizeWith :: forall m a. StrMapIsh m => Eq a => Normalizer m a -> Expr m a -> Expr m a
normalizeWith ctx = extract <<< extract <<< unwrap <<< normalizeWithW ctx

type W = Compose (Tuple (Conj Boolean)) Lazy

normalizeWithW :: forall m a. StrMapIsh m => Eq a =>
  Normalizer m a -> Expr m a ->
  W (Expr m a)
normalizeWithW ctx = rewriteBottomUpA' rules where
  onP :: forall e v r.
    Preview' e v ->
    (v -> r) -> (e -> r) ->
    e -> r
  onP p this other e = case Lens.preview p e of
    Just v -> this v
    _ -> other e

  onPW :: forall v r.
    Preview' (AST.ExprLayer m a) v ->
    (v -> r) -> (W (Expr m a) -> r) ->
    W (Expr m a) -> r
  onPW p this other e = case Lens.preview p (projectW (extractW e)) of
    Just v -> this v
    _ -> other e

  previewE :: forall ft f o' e.
    Recursive ft f =>
    Newtype (f ft) o' =>
    Preview' o' e ->
    ft -> Maybe e
  previewE p = Lens.preview p <<< unwrap <<< project
  previewEW :: forall ft f o' e.
    Recursive ft f =>
    Newtype (f ft) o' =>
    Preview' o' e ->
    W ft -> Maybe e
  previewEW p = previewE p <<< extractW
  unPairW ::  forall ft f o' e r.
    Recursive ft f =>
    Newtype (f ft) o' =>
    Preview' o' e ->
    (W ft -> W ft -> Maybe e -> Maybe e -> r) ->
    AST.Pair (W ft) ->
    r
  unPairW p f (AST.Pair l r) = f l r
    (previewEW p l)
    (previewEW p r)
  unPairNW ::  forall ft f o' e e' r.
    Recursive ft f =>
    Newtype (f ft) o' =>
    Newtype e e' =>
    Preview' o' e ->
    (W ft -> W ft -> Maybe e' -> Maybe e' -> r) ->
    AST.Pair (W ft) ->
    r
  unPairNW p = unPairW (unsafeCoerce p)
  unPair ::  forall ft f o' e r.
    Recursive ft f =>
    Newtype (f ft) o' =>
    Preview' o' e ->
    (ft -> ft -> Maybe e -> Maybe e -> r) ->
    AST.Pair (ft) ->
    r
  unPair p f (AST.Pair l r) = f l r
    (previewE p l)
    (previewE p r)
  unPairN ::  forall ft f o' e e' r.
    Recursive ft f =>
    Newtype (f ft) o' =>
    Newtype e e' =>
    Preview' o' e ->
    (ft -> ft -> Maybe e' -> Maybe e' -> r) ->
    AST.Pair (ft) ->
    r
  unPairN p = unPair (unsafeCoerce p)

  -- The companion to judgmentallyEqual for terms that are already
  -- normalized recursively from this
  judgEq = (eq :: Expr m a -> Expr m a -> Boolean) `on` (extractW >>> Variables.alphaNormalize)

  extractW :: forall x. W x -> x
  extractW (Compose x) = extract (extract x)

  deferred :: forall x. (Unit -> x) -> W x
  deferred x = Compose $ pure (defer x)

  simpler :: forall x. W x -> W x
  simpler (Compose (Tuple _ x)) = Compose $ Tuple (Conj false) x

  instead :: forall x. (Unit -> x) -> W x
  instead x = simpler (deferred x)

  rules = identity
    >>> VariantF.on (_S::S_ "Annot")
      (\(AST.Pair e _) -> simpler e)
    >>> onP AST._Let
      (\{ var, ty: _, value, body } ->
        instead \_ -> normalizeWith ctx $
          Variables.shiftSubstShift0 var (extractW value) (extractW body)
      )
    >>> VariantF.on (_S::S_ "BoolAnd")
      (unPairNW AST._BoolLit \l r -> case _, _ of
        Just true, _ -> simpler r -- (l = True) && r -> r
        Just false, _ -> simpler l -- (l = False) && r -> (l = False)
        _, Just false -> simpler r -- l && (r = False) -> (r = False)
        _, Just true -> simpler l -- l && (r = True) -> l
        _, _ ->
          if judgEq l r
          then simpler l
          else lift2 AST.mkBoolAnd l r
      )
    >>> VariantF.on (_S::S_ "BoolOr")
      (unPairNW AST._BoolLit \l r -> case _, _ of
        Just true, _ -> simpler l -- (l = True) || r -> (l = True)
        Just false, _ -> simpler r -- (l = False) || r -> r
        _, Just false -> simpler l -- l || (r = False) -> l
        _, Just true -> simpler r -- l || (r = True) -> (r = True)
        _, _ ->
          if judgEq l r
          then simpler l
          else lift2 AST.mkBoolOr l r
      )
    >>> VariantF.on (_S::S_ "BoolEQ")
      (unPairNW AST._BoolLit \l r -> case _, _ of
        Just a, Just b -> instead \_ -> AST.mkBoolLit (a == b)
        Just true, _ -> simpler r
        _, Just true -> simpler l
        _, _ ->
          if judgEq l r
          then instead \_ -> AST.mkBoolLit true
          else lift2 AST.mkBoolEQ l r
      )
    >>> VariantF.on (_S::S_ "BoolNE")
      (unPairNW AST._BoolLit \l r -> case _, _ of
        Just a, Just b -> instead \_ -> AST.mkBoolLit (a /= b)
        Just false, _ -> simpler r
        _, Just false -> simpler l
        _, _ ->
          if judgEq l r
          then instead \_ -> AST.mkBoolLit false
          else lift2 AST.mkBoolNE l r
      )
    >>> VariantF.on (_S::S_ "BoolIf")
      (\(AST.Triplet b t f) ->
        let p = AST._BoolLit <<< _Newtype in
        case previewEW p b of
          Just true -> simpler t
          Just false -> simpler f
          Nothing ->
            case previewEW p t, previewEW p f of
              Just true, Just false -> simpler b
              _, _ ->
                if judgEq t f
                  then simpler t
                  else lift3 AST.mkBoolIf b t f
      )
    >>> VariantF.on (_S::S_ "NaturalPlus")
      (unPairNW AST._NaturalLit \l r -> case _, _ of
        Just a, Just b -> instead \_ -> AST.mkNaturalLit (a + b)
        Just a, _ | a == zero -> simpler r
        _, Just b | b == zero -> simpler l
        _, _ -> lift2 AST.mkNaturalPlus l r
      )
    >>> VariantF.on (_S::S_ "NaturalTimes")
      (unPairNW AST._NaturalLit \l r -> case _, _ of
        Just a, Just b -> instead \_ -> AST.mkNaturalLit (a * b)
        Just a, _ | a == zero -> simpler l
        _, Just b | b == zero -> simpler r
        Just a, _ | a == one -> simpler r
        _, Just b | b == one -> simpler l
        _, _ -> lift2 AST.mkNaturalTimes l r
      )
    >>> VariantF.on (_S::S_ "TextLit")
      (
        let
          go (AST.TextLit s) = pure (AST.TextLit s)
          go (AST.TextInterp s v tl) =
            (v # extractW # projectW # onP AST._TextLit
              do \tl2 tl' -> ((AST.TextLit s <> tl2) <> _) <$> tl'
              do \_ tl' -> lift2 (AST.TextInterp s) v tl'
            ) (go tl)
          finalize tl = case extractW tl of
            AST.TextInterp "" v' (AST.TextLit "") -> instead \_ -> v'
            _ -> AST.mkTextLit <$> tl
        in finalize <<< go
      )
    >>> VariantF.on (_S::S_ "TextAppend")
      (unPairW AST._TextLit \l r -> case _, _ of
        Just a, Just b -> instead \_ -> AST.mkTextLit (a <> b)
        Just a, _ | a == mempty -> simpler r
        _, Just b | b == mempty -> simpler l
        _, _ -> lift2 AST.mkTextAppend l r
      )
    >>> VariantF.on (_S::S_ "ListLit")
      (\(Product (Tuple mty vs)) ->
        -- Remove annotation on non-empty lists
        if not Array.null vs && isJust mty
          then simpler (AST.mkListLit Nothing <$> sequence vs)
          else AST.mkListLit <$> sequence mty <*> sequence vs
      )
    >>> VariantF.on (_S::S_ "ListAppend")
      (unPairW AST._ListLit \l r -> case _, _ of
        Just { ty, values: a }, Just { values: b } ->
          instead \_ -> AST.mkListLit ty (a <> b)
        Just { values: [] }, _ -> simpler r
        _, Just { values: [] } -> simpler l
        _, _ -> lift2 AST.mkListAppend l r
      )
    >>> VariantF.on (_S::S_ "OptionalLit")
      (\(Product (Tuple (Identity ty) mv)) ->
        case mv of
          Nothing -> AST.mkApp AST.mkNone <$> ty
          Just v -> AST.mkSome <$> v
      )
    >>> VariantF.on (_S::S_ "Combine")
      (let
        decideThese = Just <<< case _ of
          This a -> a
          That b -> b
          Both a b -> decide (AST.Pair a b)
        decide = unPair AST._RecordLit \l r -> case _, _ of
          Just a, Just b ->
            AST.mkRecordLit $
              StrMapIsh.unionWith (pure decideThese) a b
          Just a, _ | StrMapIsh.isEmpty a -> r
          _, Just b | StrMapIsh.isEmpty b -> l
          _, _ -> AST.mkCombine l r
        decideTop = unPairW AST._RecordLit \l r -> case _, _ of
          Just a, Just b -> instead \_ ->
            AST.mkRecordLit $
              StrMapIsh.unionWith (pure decideThese) a b
          Just a, _ | StrMapIsh.isEmpty a -> simpler r
          _, Just b | StrMapIsh.isEmpty b -> simpler l
          _, _ -> lift2 AST.mkCombine l r
      in decideTop)
    >>> VariantF.on (_S::S_ "CombineTypes")
      (let
        decideThese = Just <<< case _ of
          This a -> a
          That b -> b
          Both a b -> decide (AST.Pair a b)
        decide = unPair AST._Record \l r -> case _, _ of
          Just a, Just b ->
            AST.mkRecord $
              StrMapIsh.unionWith (pure decideThese) a b
          Just a, _ | StrMapIsh.isEmpty a -> r
          _, Just b | StrMapIsh.isEmpty b -> l
          _, _ -> AST.mkCombineTypes l r
        decideTop = unPairW AST._Record \l r -> case _, _ of
          Just a, Just b -> instead \_ ->
            AST.mkRecord $
              StrMapIsh.unionWith (pure decideThese) a b
          Just a, _ | StrMapIsh.isEmpty a -> simpler r
          _, Just b | StrMapIsh.isEmpty b -> simpler l
          _, _ -> lift2 AST.mkCombineTypes l r
      in decideTop)
    >>> VariantF.on (_S::S_ "Prefer")
      (let
        preference = Just <<< case _ of
          This a -> a
          That b -> b
          Both a _ -> a
        decide = unPairW AST._RecordLit \l r -> case _, _ of
          Just a, Just b -> instead \_ ->
            AST.mkRecordLit $
              StrMapIsh.unionWith (pure preference) a b
          Just a, _ | StrMapIsh.isEmpty a -> simpler r
          _, Just b | StrMapIsh.isEmpty b -> simpler l
          _, _ -> lift2 AST.mkPrefer l r
      in decide)
    >>> VariantF.on (_S::S_ "Merge")
      (\(AST.MergeF x y mty) ->
          let
            default _ = AST.mkMerge <$> x <*> y <*> sequence mty
          in x # onPW AST._RecordLit
            do \kvsX ->
              y # onPW AST._UnionLit
                do \{ label: kY, value: vY } ->
                    case IOSM.get kY kvsX of
                      Just vX -> instead \_ ->
                        normalizeWith ctx $ AST.mkApp vX vY
                      _ -> default unit
                do \_ -> default unit
            do \_ -> default unit
      )
    >>> VariantF.on (_S::S_ "Constructors")
      (un Identity >>> \e' -> case previewEW AST._Union e' of
        Just kts -> instead \_ ->
          AST.mkRecord $ kts # mapWithIndex \k t_ ->
            AST.mkLam k (t_) $ AST.mkUnionLit k (AST.mkVar (AST.V k 0)) $
              (fromMaybe <*> StrMapIsh.delete k) kts
        Nothing -> map AST.mkConstructors e'
      )
    >>> VariantF.on (_S::S_ "Field")
      (\(Tuple k r) ->
        let
          default _ = AST.mkField <$> r <@> k
        in r # onPW AST._RecordLit
          do
            \kvs ->
              case IOSM.get k kvs of
                Just v -> instead \_ -> v
                _ -> default unit
          do onPW AST._Union
              do \kvs ->
                case IOSM.get k kvs, IOSM.delete k kvs of
                  Just ty, Just rest ->
                    instead \_ -> normalizeWith ctx $
                      AST.mkLam k ty $ AST.mkUnionLit k (AST.mkVar (AST.V k 0)) rest
                  _, _ -> default unit
              do \_ -> default unit
      )
    >>> VariantF.on (_S::S_ "Project")
      (\(Tuple (AppF.App ks) r) ->
        let
          default _ = AST.mkProject <$> r <@> ks
        in r # onPW AST._RecordLit
          do
            \kvs ->
              let
                adapt = case _ of
                  Both (_ :: Unit) v -> Just v
                  _ -> Nothing
              in case sequence $ IOSM.unionWith (pure (pure <<< adapt)) ks kvs of
                Just vs' -> instead \_ -> normalizeWith ctx $
                  AST.mkRecordLit vs'
                _ -> default unit
          do \_ -> default unit
      )
    -- NOTE: eta-normalization, added
    >>> onP AST._Lam
      (\{ var, ty, body } ->
        AST.projectW (extractW body) #
        let
          default _ = AST.embedW (extractW <$> Lens.review AST._Lam { var, ty, body })
        in pure (deferred default)
        # onP AST._App
          \{ fn, arg } ->
            let var0 = AST.V var 0 in
            if arg == AST.mkVar var0 && not (un Disj (Variables.freeIn var0 fn))
              then instead \_ -> fn
              else deferred default
      )
    -- composing with <<< gives this case priority
    >>> identity <<< onP AST._App \{ fn, arg } ->
      projectW (extractW fn) # onP AST._Lam
        (\{ var, body } -> instead \_ ->
          normalizeWith ctx $ Variables.shiftSubstShift0 var (extractW arg) body
        ) \_ ->
        case normalizeFns ctx (extractW fn) (extractW arg) of
          Just ret -> instead ret
          _ -> lift2 AST.mkApp fn arg

normalizeFns :: forall m a. StrMapIsh m => Eq a =>
  Normalizer m a ->
  Expr m a -> Expr m a ->
  Maybe (Unit -> Expr m a)
normalizeFns ctx fn arg =
  unwrap (builtins ctx <> ctx)
    (Lens.view apps fn ~ Lens.view apps arg)

builtins :: forall m a. StrMapIsh m => Eq a => Normalizer m a -> Normalizer m a
builtins ctx = fusions ctx <> conversions ctx <> naturalfns ctx <> optionalfns ctx <> listfns ctx

fusions :: forall m a. StrMapIsh m => Eq a => Normalizer m a -> Normalizer m a
fusions ctx = Normalizer case _ of
  -- build/fold fusion for `List`
  -- App (App ListBuild _) (App (App ListFold _) e') -> loop e'
  listbuild~_~(listfold~_~e')
    | noapp AST._ListBuild listbuild
    , noapp AST._ListFold listfold ->
      pure \_ -> Lens.review apps e'
  -- build/fold fusion for `Natural`
  -- App NaturalBuild (App NaturalFold e') -> loop e'
  naturalbuild~(naturalfold~e')
    | noapp AST._NaturalBuild naturalbuild
    , noapp AST._NaturalFold naturalfold ->
      pure \_ -> Lens.review apps e'
  -- build/fold fusion for `Optional`
  -- App (App OptionalBuild _) (App (App OptionalFold _) e') -> loop e'
  optionalbuild~_~(optionalfold~_~e')
    | noapp AST._OptionalBuild optionalbuild
    , noapp AST._OptionalFold optionalfold ->
      pure \_ -> Lens.review apps e'
  _ -> empty

conversions :: forall m a. StrMapIsh m => Eq a => Normalizer m a -> Normalizer m a
conversions ctx = Normalizer case _ of
  naturaltointeger~naturallit
    | noapp AST._NaturalToInteger naturaltointeger
    , Just n <- noapplit AST._NaturalLit naturallit ->
      pure \_ -> AST.mkIntegerLit (natToInt n)
  naturalshow~naturallit
    | noapp AST._NaturalShow naturalshow
    , Just n <- noapplit AST._NaturalLit naturallit ->
      pure \_ -> AST.mkTextLit (AST.TextLit (show n))
  integershow~integerlit
    | noapp AST._IntegerShow integershow
    , Just n <- noapplit AST._IntegerLit integerlit ->
      let s = if n >= 0 then "+" else "" in
      pure \_ -> AST.mkTextLit (AST.TextLit (s <> show n))
  integertodouble~integerlit
    | noapp AST._IntegerToDouble integertodouble
    , Just n <- noapplit AST._IntegerLit integerlit ->
      pure \_ -> AST.mkDoubleLit (toNumber n)
  doubleshow~doublelit
    | noapp AST._DoubleShow doubleshow
    , Just n <- noapplit AST._DoubleLit doublelit ->
      pure \_ -> AST.mkTextLit (AST.TextLit (show n))
  _ -> Nothing

naturalfns :: forall m a. StrMapIsh m => Eq a => Normalizer m a -> Normalizer m a
naturalfns ctx = Normalizer case _ of
  -- App (App (App (App NaturalFold (NaturalLit n0)) t) succ') zero
  naturalfold~naturallit~t~succ'~zero'
    | noapp AST._NaturalFold naturalfold
    , Just n0 <- noapplit AST._NaturalLit naturallit -> pure \_ ->
      let
        t' = normalizeWith ctx (Lens.review apps t)
        succE = Lens.review apps succ'
        zeroE = Lens.review apps zero'
      in if boundedType t'
        then
          let
            strictLoop n =
              if n > zero then
                normalizeWith ctx (AST.mkApp succE (strictLoop (n +- one)))
              else normalizeWith ctx zeroE
          in strictLoop n0
        else
          let
            lazyLoop n =
              if n > zero then
                AST.mkApp succE (lazyLoop (n +- one))
              else zeroE
          in normalizeWith ctx (lazyLoop n0)
  naturalbuild~g
    | noapp AST._NaturalBuild naturalbuild -> pure \_ ->
      let
        zero_ = AST.mkNaturalLit zero
        succ_ = AST.mkLam "x" AST.mkNatural $
          AST.mkNaturalPlus (AST.mkVar (AST.V "x" 0)) $ AST.mkNaturalLit one
        g' = Lens.review apps g
      in normalizeWith ctx $
        AST.mkApp (AST.mkApp (AST.mkApp g' AST.mkNatural) succ_) zero_
  naturaliszero~naturallit
    | noapp AST._NaturalIsZero naturaliszero
    , Just n <- noapplit AST._NaturalLit naturallit ->
      pure \_ -> AST.mkBoolLit (n == zero)
  naturaleven~naturallit
    | noapp AST._NaturalEven naturaleven
    , Just n <- noapplit AST._NaturalLit naturallit ->
      pure \_ -> AST.mkBoolLit (even (natToInt n))
  naturalodd~naturallit
    | noapp AST._NaturalOdd naturalodd
    , Just n <- noapplit AST._NaturalLit naturallit ->
      pure \_ -> AST.mkBoolLit (not even (natToInt n))
  _ -> Nothing

optionalfns :: forall m a. StrMapIsh m => Eq a => Normalizer m a -> Normalizer m a
optionalfns ctx = Normalizer case _ of
  optionalbuild~t~g
    | noapp AST._OptionalBuild optionalbuild -> pure \_ ->
      let
        g' = Lens.review apps g
        ty = Lens.review apps t
        optional = AST.mkApp AST.mkOptional ty
        just = AST.mkLam "a" ty (AST.mkSome (AST.mkVar (AST.V "a" 0)))
        nothing = AST.mkApp AST.mkNone ty
      in normalizeWith ctx
        (AST.mkApp (AST.mkApp (AST.mkApp g' optional) just) nothing)
  optionalfold~_~(none~_)~_~_~nothing
    | noapp AST._OptionalFold optionalfold
    , noapp AST._None none -> pure \_ ->
      -- TODO: I don't think this is necessary
      -- normalizeWith ctx $
      (Lens.review apps nothing)
  optionalfold~_~some~_~just~_
    | noapp AST._OptionalFold optionalfold
    , Just (Identity x) <- noapplit' (AST._ExprFPrism (_S::S_ "Some")) some ->
      pure \_ -> normalizeWith ctx $
        AST.mkApp (Lens.review apps just) x
  _ -> Nothing

listfns :: forall m a. StrMapIsh m => Eq a => Normalizer m a -> Normalizer m a
listfns ctx = Normalizer case _ of
  listbuild~t~g
    | noapp AST._ListBuild listbuild -> pure \_ ->
      let
        g' = Lens.review apps g
        ty = Lens.review apps t
        ty' = Variables.shift 1 (AST.V "a" 0) ty
        list = AST.mkApp AST.mkList ty
        cons = AST.mkLam "a" ty $
          AST.mkLam "as" (AST.mkApp AST.mkList ty') $
            AST.mkListAppend
              (AST.mkListLit Nothing (pure (AST.mkVar (AST.V "a" 0))))
              (AST.mkVar (AST.V "as" 0))
        nil = AST.mkListLit (Just ty) empty
      in normalizeWith ctx
        (AST.mkApp (AST.mkApp (AST.mkApp g' list) cons) nil)
  listfold~_~listlit~t~cons~nil
    | noapp AST._ListFold listfold
    , Just (Product (Tuple _ xs)) <- noapplit' (AST._ExprFPrism (_S::S_ "ListLit")) listlit ->
      pure \_ ->
      let
        t' = normalizeWith ctx (Lens.review apps t)
        consE = Lens.review apps cons
        nilE = Lens.review apps nil
      in if boundedType t'
        then
          let
            strictNil = normalizeWith ctx nilE
            strictCons y ys = normalizeWith ctx
              (AST.mkApp (AST.mkApp consE y) ys)
          in foldr strictCons strictNil xs
        else
          let
            lazyNil = nilE
            lazyCons y ys = AST.mkApp (AST.mkApp consE y) ys
          in normalizeWith ctx (foldr lazyCons lazyNil xs)
  listlength~_~listlit
    | noapp AST._ListLength listlength
    , Just (Product (Tuple _ xs)) <- noapplit' (AST._ExprFPrism (_S::S_ "ListLit")) listlit ->
      pure \_ ->
        AST.mkNaturalLit (intToNat (Array.length xs))
  listhead~t~listlit
    | noapp AST._ListHead listhead
    , Just (Product (Tuple _ xs)) <- noapplit' (AST._ExprFPrism (_S::S_ "ListLit")) listlit ->
      pure \_ -> normalizeWith ctx $
      case Array.head xs of
        Just x -> AST.mkSome x
        Nothing -> AST.mkApp AST.mkNone (Lens.review apps t)
  listlast~t~listlit
    | noapp AST._ListLast listlast
    , Just (Product (Tuple _ xs)) <- noapplit' (AST._ExprFPrism (_S::S_ "ListLit")) listlit ->
      pure \_ -> normalizeWith ctx $
      case Array.last xs of
        Just x -> AST.mkSome x
        Nothing -> AST.mkApp AST.mkNone (Lens.review apps t)
  listindexed~t~listlit
    | noapp AST._ListIndexed listindexed
    , Just (Product (Tuple _ xs)) <- noapplit' (AST._ExprFPrism (_S::S_ "ListLit")) listlit ->
      pure \_ -> normalizeWith ctx $
        let
          mty' = if Array.null xs then Nothing else
            Just $ AST.mkRecord $ IOSM.fromFoldable
              [ Tuple "index" AST.mkNatural
              , Tuple "value" (Lens.review apps t)
              ]
          adapt i x = AST.mkRecordLit $ IOSM.fromFoldable
            [ Tuple "index" (AST.mkNaturalLit (intToNat i))
            , Tuple "value" x
            ]
        in AST.mkListLit mty' (mapWithIndex adapt xs)
  listreverse~_~listlit
    | noapp AST._ListReverse listreverse
    , Just (Product (Tuple mty xs)) <- noapplit' (AST._ExprFPrism (_S::S_ "ListLit")) listlit ->
      pure \_ -> normalizeWith ctx $
        AST.mkListLit mty (Array.reverse xs)
  _ -> Nothing

-- | Returns `true` if two expressions are α-equivalent and β-equivalent and
-- | `false` otherwise
judgmentallyEqual :: forall m a. StrMapIsh m => Eq a => Expr m a -> Expr m a -> Boolean
judgmentallyEqual eL0 eR0 = alphaBetaNormalize eL0 == alphaBetaNormalize eR0
  where
    alphaBetaNormalize :: Expr m a -> Expr m a
    alphaBetaNormalize = Variables.alphaNormalize <<< normalize

-- | Check if an expression is in a normal form given a context of evaluation.
-- | Unlike `isNormalized`, this will fully normalize and traverse through the expression.
--
-- | It is much more efficient to use `isNormalized`.
isNormalized :: forall m a. StrMapIsh m => Eq a => Expr m a -> Boolean
isNormalized = isNormalizedWith mempty

-- | ~Quickly~ Check if an expression is in normal form
isNormalizedWith :: forall m a. StrMapIsh m => Eq a => Normalizer m a -> Expr m a -> Boolean
isNormalizedWith ctx e0 = case normalizeWithW ctx e0 of
  Compose (Tuple (Conj wasNormalized) _) -> wasNormalized
