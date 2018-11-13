module Dhall.Interactive where

import Prelude

import Complex.Validation.These as V
import Control.Coroutine (consumer)
import Control.Monad.Free (Free)
import Control.Monad.Free as Free
import Control.Monad.State (class MonadState, State, StateT(..), evalState)
import Control.Monad.Writer (runWriterT)
import Data.Array as Array
import Data.Bifunctor (bimap, lmap)
import Data.Const (Const(..))
import Data.Either (Either(..), either)
import Data.Functor.Compose (Compose(..))
import Data.Functor.Variant (FProxy, VariantF)
import Data.Functor.Variant as VariantF
import Data.Identity (Identity(..))
import Data.Lens (review, view)
import Data.Maybe (Maybe(..))
import Data.Natural (Natural, intToNat)
import Data.Newtype (class Newtype, unwrap, wrap)
import Data.Profunctor (dimap)
import Data.Profunctor.Star (Star(..))
import Data.String (joinWith)
import Data.Symbol (SProxy(..))
import Data.Tuple (Tuple(..), fst)
import Dhall.Context as Dhall.Context
import Dhall.Core ((~))
import Dhall.Core as Core
import Dhall.Core as Dhall.Core
import Dhall.Core.AST as AST
import Dhall.Core.Imports as Core.Imports
import Dhall.Core.StrMapIsh as IOSM
import Dhall.Interactive.Halogen.Inputs as Inputs
import Dhall.Interactive.Halogen.Types (DataComponent)
import Dhall.Interactive.Halogen.Types as Types
import Dhall.Interactive.Halogen.Types.Natural as Types.Natural
import Dhall.Interactive.Types (InteractiveExpr, Annotation)
import Dhall.Parser (parse')
import Dhall.TypeCheck (typeWithA)
import Dhall.TypeCheck as TypeCheck
import Effect (Effect)
import Effect.Aff (Aff)
import Effect.Class.Console (logShow)
import Halogen as H
import Halogen.Aff as HA
import Halogen.Component as HC
import Halogen.Expanding as TCHE
import Halogen.HTML as HH
import Halogen.HTML.Elements.Keyed as HK
import Halogen.HTML.Events as HE
import Halogen.HTML.Properties as HP
import Halogen.VDom.Driver (runUI)
import Halogen.VDom.Thunk as Thunk
import Halogen.Zuruzuru as Zuruzuru
import Matryoshka (cata)
import Unsafe.Coerce (unsafeCoerce)
import Web.Util.TextCursor as TC

data Q a
  = ZZ (Zuruzuru.Message String) a
  | Swap a

type Slots =
  ( expanding :: H.Slot Inputs.QueryExpanding String Zuruzuru.Key
  , naturalH :: Types.DataSlot Natural
  )

newtype SlottedHTML o = SlottedHTML (H.ComponentHTML' o Slots Aff)
instance functorSlottedHTML :: Functor SlottedHTML where
  map f (SlottedHTML h) =  SlottedHTML $ bimap mapSlot f h where
    mapSlot (HC.ComponentSlot s) = HC.ComponentSlot $ map f s
    mapSlot (HC.ThunkSlot s) = HC.ThunkSlot $ Thunk.hoist (lmap mapSlot) $ map f s
derive instance newtypeSlottedHTML :: Newtype (SlottedHTML o) _

type SlottingHTML = Compose (State Int) SlottedHTML

interactive :: H.Component HH.HTML Q Unit Void Aff
interactive = H.component
  { initializer: Nothing
  , finalizer: Nothing
  , receiver: pure Nothing
  , initialState: pure { values: [], shown: true }
  , eval: case _ of
      ZZ (Zuruzuru.NewState v) a -> a <$ H.modify_ _ { values = v }
      ZZ (Zuruzuru.Added info) a -> a <$ do
        H.query (SProxy :: SProxy "zuruzuru") unit $
          Zuruzuru.queryInside (SProxy :: SProxy "expanding") info.key $
            Inputs.PassOn $ (TCHE.set (TCHE.Focused TC.empty) *> TCHE.get)
      ZZ _ a -> pure a
      Swap a -> a <$ H.modify_ \r -> r { shown = not r.shown }
  , render
  } where
    lifting (Left m) = Just (ZZ m unit)
    lifting (Right _) = Just (Swap unit)

    render ::
      { values :: Array String, shown :: Boolean } ->
      H.ComponentHTML
        Q
        ( zuruzuru :: Zuruzuru.Slot' Slots Aff Unit String Unit )
        Aff
    render { shown: false } =
      HH.div [ HP.class_ $ H.ClassName "ast" ]
        [ HH.text "{"
        , Inputs.inline_feather_button_action (Just (Swap unit)) "maximize"
        , HH.text "}"
        ]
    render { values: vs } =
      HH.slot Zuruzuru._zuruzuru unit Zuruzuru.zuruzuru' (com vs) lifting

    com :: Array String -> Zuruzuru.Input' Slots Aff Unit String
    com vs =
      { values: vs
      , direction: Zuruzuru.Vertical
      , default: pure mempty
      , renderer
      }

    renderer = Zuruzuru.Renderer \datums { add, output } ->
      HH.div [ HP.class_ $ H.ClassName "ast" ] $ pure $
      let postpend = add (Array.length datums) in
      if Array.null datums
      then HH.span_
          [ HH.text "{"
          , Inputs.inline_feather_button_action (Just postpend) "plus-square"
          , HH.text "}"
          ]
      else HK.div [ HP.class_ $ H.ClassName "grid-container" ]
        let
          items = datums <#> \{ helpers, handle, info } ->
            let
              moving :: forall r i. HP.IProp ( style :: String | r ) i
              moving = HP.attr (H.AttrName "style") $
                "transform: translateY(" <> show info.offset <> "px)"
            in Tuple info.key $ HH.div [ HP.class_ $ H.ClassName "row" ]
            [ Inputs.inline_feather_button_action (Just (output unit))
              if info.index == 0
              then "minimize"
              else "more-vertical"
            , HH.div_ [ HH.text if info.index == 0 then "{" else "," ]
            , Inputs.icon_button_props
              [ moving
              , HP.ref handle.label
              , HE.onMouseDown handle.onMouseDown
              , HP.class_ (H.ClassName "move")
              , HP.tabIndex (-1)
              ] "menu" "feather inline active move vertical"
            , Inputs.inline_feather_button_props [ moving, HE.onClick (\_ -> Just helpers.remove) ] "minus-square"
            , HH.span [ HP.class_ (H.ClassName "input-parent"), moving ]
              [ HH.slot (SProxy :: SProxy "expanding") info.key
                  (Inputs.expanding HP.InputText) info.value (Just <<< helpers.set)
              ]
            ]
        in items <>
          [ Tuple "" $ HH.div
            [ HP.class_ $ H.ClassName "row" ]
            [ Inputs.inline_feather_button_action (Just (output unit)) "minimize"
            , HH.text "}"
            , Inputs.inline_feather_button_action (Just postpend) "plus-square"
            ]
          ]

type ExprRow =
  ( "NaturalLit" :: AST.CONST Natural
  , "NaturalPlus" :: FProxy AST.Pair
  -- , "NaturalTimes" :: FProxy AST.Pair
  )
newtype Expr a = Expr (Free (VariantF ExprRow) a)
derive instance newtypeExpr :: Newtype (Expr a) _

upcast :: Expr Void -> InteractiveExpr Annotation
upcast = unsafeCoerce

instance showExpr :: Show (Expr Void) where
  show a = show (upcast a :: InteractiveExpr Annotation)
instance eqExpr :: Eq (Expr Void) where
  eq a b = eq
    (upcast a :: InteractiveExpr Annotation)
    (upcast b :: InteractiveExpr Annotation)

mkNaturalLit :: forall a. Natural -> Expr a
mkNaturalLit n = Expr $ Free.wrap $
  VariantF.inj (SProxy :: SProxy "NaturalLit") $ Const n

mkNaturalPlus :: forall a. Expr a -> Expr a -> Expr a
mkNaturalPlus l r = Expr $ Free.wrap $
  VariantF.inj (SProxy :: SProxy "NaturalPlus") $ map unwrap $ AST.Pair l r

rNaturalPlus :: forall ir or a.
  (Types.RenderValue_ SlottingHTML a -> Types.RenderVariantF_' SlottingHTML ir or a) ->
  Types.RenderValue_ SlottingHTML a ->
  Types.RenderVariantF_' SlottingHTML
    ( "NaturalPlus" :: FProxy AST.Pair | ir )
    ( "NaturalPlus" :: FProxy AST.Pair | or ) a
rNaturalPlus = Types.renderOn (SProxy :: SProxy "NaturalPlus")
  \a -> Star \p -> Compose $
    Types.renderPairC a p <#> \(AST.Pair l r) ->
      wrap $ HH.span_ [ unwrap l, HH.text "+", unwrap r ]

rExpr1 :: forall a.
  Types.RenderValue_ SlottingHTML a ->
  Types.RenderValue_ SlottingHTML (VariantF ExprRow a)
rExpr1 = rNaturalPlus $ Types.renderOn (SProxy :: SProxy "NaturalLit")
  (const $ dimap unwrap wrap $ component) $ const (Star VariantF.case_) where
    component :: Types.RenderValue_ SlottingHTML Natural
    component = Star \i -> Compose $ StateT \ix -> Identity $ Tuple <@> (ix+1) $
      SlottedHTML $
        HH.slot (SProxy :: SProxy "naturalH") ix Types.Natural.component i pure

rExpr' :: Types.RenderValue_ SlottingHTML (Free (VariantF ExprRow) Void)
rExpr' = Star \f -> case Free.resume f of
  Left l -> Free.wrap <$> (unwrap (rExpr1 rExpr') l)
  Right r -> absurd r

rExpr :: Types.RenderValue_ SlottingHTML (Expr Void)
rExpr = Star \e -> map wrap $ wrap $ unwrap (unwrap rExpr' (unwrap e)) <#>
  \s' -> SlottedHTML $
    HH.div [ HP.class_ $ H.ClassName "ast" ] [ unwrap s' ]

putting :: forall s m. MonadState s m => Eq s => s -> m Unit -> m Unit
putting s' act = do
  s <- H.get
  if s /= s' then H.put s' *> act else pure unit

simpleC :: forall v. Eq v =>
  Types.RenderValue_ SlottingHTML v ->
  DataComponent v Aff
simpleC renderer = H.component
  { initializer: Nothing
  , finalizer: Nothing
  , receiver: Just <<< Types.In unit
  , initialState: identity
  , eval: case _ of
      Types.In a v -> a <$ putting v (pure unit)
      Types.Out a v -> a <$ putting v (H.raise v)
  , render: unwrap renderer >>> unwrap >>> flip evalState 0 >>>
      map (Types.Out unit) >>> unwrap
  }

example :: Expr Void
example = mkNaturalPlus (mkNaturalLit (intToNat 2)) (mkNaturalLit (intToNat 2))

eval :: Expr Void -> Expr Void
eval = (<<<) mkNaturalLit $ (>>>) unwrap $ cata $ (>>>) unwrap $ either absurd $
  VariantF.case_
  # VariantF.on (SProxy :: SProxy "NaturalLit") unwrap
  # VariantF.on (SProxy :: SProxy "NaturalPlus")
    (\(AST.Pair l r) -> l + r)

denote :: forall s. AST.Expr IOSM.InsOrdStrMap s Core.Imports.Import -> AST.Expr IOSM.InsOrdStrMap Void Core.Imports.Import
denote = Core.denote

parserC :: Types.RenderValue String
parserC = Star \s -> HH.div [ HP.class_ $ H.ClassName "code" ]
  let
    parsed = parse' s
    showError :: TypeCheck.TypeCheckError (TypeCheck.Errors () IOSM.InsOrdStrMap Void Core.Imports.Import) IOSM.InsOrdStrMap Void Core.Imports.Import -> String
    showError = unsafeCoerce >>> _.tag >>> _.type
    ctx = Dhall.Context.empty # Dhall.Context.insert "Test/equal" do
      AST.mkPi "a" AST.mkType (AST.mkPi "_" (AST.mkVar (AST.V "a" 0)) (AST.mkPi "_" (AST.mkVar (AST.V "a" 0)) AST.mkBool))
    typechecked = bimap showError fst <<< runWriterT <<< typeWithA (\_ -> AST.mkType) ctx =<< V.note "Parse fail" parsed
    shown = case typechecked of
      V.Error es _ -> (<>) "Errors: " $
        joinWith "; " <<< Array.fromFoldable $
          map (joinWith ", " <<< Array.fromFoldable) es
      V.Success a -> "Success: " <> show a
    normalized :: Maybe (AST.Expr IOSM.InsOrdStrMap Void Core.Imports.Import)
    normalized = case typechecked of
      V.Success _ ->
        -- Funny thing: the `normalizer` does not obey any laws of normalization
        -- because it inspects its arguments too much, takes them verbatim
        -- and wholly consumes them ... due to a bug in my implementation
        -- this means that it would see unnormalized terms, when let/lambda
        -- bound variables are involved (since the normalization happens
        -- bottom-to-top, and then the let/lambda bindings are renormalized
        -- after substitution). So, to circumvent this, the normalizer is run
        -- only after the regular normalization (and substituion) has happened.
        Dhall.Core.normalizeWith normalizator <<< Dhall.Core.normalize <$> parsed
      _ -> Nothing
    normalizator :: forall s.
      AST.Expr IOSM.InsOrdStrMap s Core.Imports.Import ->
      AST.Expr IOSM.InsOrdStrMap s Core.Imports.Import ->
      Maybe (AST.Expr IOSM.InsOrdStrMap s Core.Imports.Import)
    normalizator f a = normalizer (view Core.apps (AST.mkApp f a))
    normalizer :: forall s.
      Dhall.Core.Apps IOSM.InsOrdStrMap s Core.Imports.Import ->
      Maybe (AST.Expr IOSM.InsOrdStrMap s Core.Imports.Import)
    normalizer (testequal~_~x~y)
      | Just (AST.V "Test/equal" 0) <- Core.noapplit AST._Var testequal
      , x' <- denote $ review Core.apps x
      , y' <- denote $ review Core.apps y =
        Just (AST.mkBoolLit (Core.judgmentallyEqual x' y'))
    normalizer _ =
        Nothing
  in
  [ HH.div_ [ HH.textarea [ HE.onValueInput Just, HP.value s ] ]
  , HH.div_ [ HH.text (show parsed) ]
  , HH.div_ [ HH.text shown ]
  , HH.div_ [ HH.text "Normalized: ", HH.text (show normalized) ]
  , HH.div_ [ HH.text "abNormalized: ", HH.text (show (Dhall.Core.alphaNormalize <$> normalized)) ]
  ]

main :: Effect Unit
main = HA.runHalogenAff do
  body <- HA.awaitBody
  driver <- runUI interactive unit body
  driver2 <- runUI (simpleC rExpr) example body
  driver2.subscribe $ consumer \v ->
    mempty <$ logShow v <* logShow (eval v)
  driver3 <- runUI (Types.simpleC parserC) "Type" body
  pure unit
