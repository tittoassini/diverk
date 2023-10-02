{-# LANGUAGE RecursiveDo #-}

module Configuration (configuration) where

import Common.Model
  ( Config (..),
    Owner (..),
    Repo (..),
    Token (..),
    owner,
    repo,
    token,
  )
import Control.Lens (to, (^.), (^?), _Just, _Wrapped)
import Control.Monad ((<=<))
import Control.Monad.Fix (MonadFix)
import Control.Monad.IO.Class (MonadIO)
import Data.Maybe (fromMaybe, isJust, isNothing)
import Data.Text (Text)
import qualified Data.Text as T
import Reflex.Dom.Core hiding (Error)
import Reflex.Extra (onClient)
import Request (contentsRequest, rateLimitRequest, usersRequest)
import Witherable (catMaybes)
import Prelude hiding (unzip)

configuration ::
  ( DomBuilder t m,
    Prerender t m,
    MonadHold t m,
    PostBuild t m,
    MonadFix m,
    PerformEvent t m,
    TriggerEvent t m,
    MonadIO (Performable m)
  ) =>
  Maybe Config ->
  m (Event t Config)
configuration mbConfig =
  elClass "div" "flex items-start md:h-screen md:pt-[20vh]" $
    elClass
      "div"
      ( T.unwords
          [ "flex",
            "flex-col",
            "md:rounded-lg",
            "md:max-w-md",
            "md:shadow",
            "w-screen",
            "w-full",
            "mx-auto",
            "gap-4",
            "p-4"
          ]
      )
      $ do
        rec dyOwner <- fmap MkOwner <$> inputOwner evOwnerValid
            dyRepo <- fmap MkRepo <$> inputRepo (updated dyRepoExists)
            dyToken <- fmap mkToken <$> inputToken (updated dyTokenValid)

            -- The owner request
            let evUserRequest = updated $ usersRequest <$> dyToken <*> dyOwner
            evOwnerResponse <- debounceAndRequest evUserRequest
            -- 401 means the token is wrong. In this case we assume the owner
            -- exists. Because the token is wrong, the form cannot be submitted
            -- anyway.
            let evOwnerValid =
                  leftmost
                    [ -- The owner is valid
                      is200Or401 <$> evOwnerResponse,
                      -- It is currently edited
                      False <$ updated dyOwner
                    ]

            -- The repo request
            let evContentRequest =
                  updated $
                    contentsRequest
                      <$> dyToken <*> dyOwner <*> dyRepo <*> pure mempty
            evRepoResponse <- debounceAndRequest evContentRequest
            -- Same remark for 401
            dyRepoExists <-
              holdDyn (isJust mbRepo) $
                leftmost
                  [ is200Or401 <$> evRepoResponse,
                    False <$ updated dyOwner,
                    False <$ updated dyRepo
                  ]

            -- The token request
            -- The token is valid:
            -- - if empty
            -- - if the rate limit endpoint returns 200
            let evToken = updated dyToken
                evMaybeTokenRequest = fmap rateLimitRequest <$> evToken
            evTokenResponse <-
              -- dont debounce the request if the token is empty
              fmap (gate (isJust <$> current dyToken))
                . debounceAndRequest
                $ catMaybes evMaybeTokenRequest
            let evTokenValidOrEmpty =
                  leftmost
                    [ -- Valid non empty token
                      is200 <$> evTokenResponse,
                      -- Empty token
                      isNothing <$> evToken,
                      -- Token currently edited
                      False <$ evToken
                    ]
            -- In the initial state, the token is either empty either loaded
            -- from the local storage. In both cases, we assume it is valid.
            dyTokenValid <- holdDyn True evTokenValidOrEmpty

        let dyCanSave = (&&) <$> dyRepoExists <*> dyTokenValid
        evSave <- saveButton dyCanSave

        let beConfig = current $ MkConfig <$> dyOwner <*> dyRepo <*> dyToken
        pure $ tag beConfig evSave
  where
    inputOwner evValid =
      inputWidget
        MkText
        "Owner"
        True
        "name"
        (fromMaybe "" mbOwner)
        (isJust mbOwner)
        evValid
        Nothing
    inputRepo evValid =
      inputWidget
        MkText
        "Repository"
        True
        "repository"
        (fromMaybe "" mbRepo)
        (isJust mbRepo)
        evValid
        Nothing
    inputToken evValid =
      inputWidget
        MkPassword
        "Token"
        False
        "github_xxx"
        (fromMaybe "" mbToken)
        True
        evValid
        (Just "Needed to access private repositories")
    saveButton dyEnable = do
      (ev, _) <-
        elDynAttr'
          "button"
          (constDyn ("class" =: buttonClasses) <> (enableAttr <$> dyEnable))
          $ text "Save"
      pure $ domEvent Click ev

    mbOwner = mbConfig ^? _Just . owner . _Wrapped
    mbRepo = mbConfig ^? _Just . repo . _Wrapped
    mbToken = mbConfig ^? _Just . token . _Just . _Wrapped

    mkToken "" = Nothing
    mkToken txToken = Just $ MkToken txToken

    debounceAndRequest = onClient . performRequestAsyncWithError <=< debounce 0.5

    is200 = checkStatus (== 200)
    is200Or401 = checkStatus (`elem` [200, 401])

    checkStatus _ (Left _) = False
    checkStatus p (Right response) = response ^. xhrResponse_status . to p

    enableAttr True = mempty
    enableAttr False = "disabled" =: "true"

data InputType = MkPassword | MkText

toText :: InputType -> Text
toText MkPassword = "password"
toText MkText = "text"

inputWidget ::
  (DomBuilder t m, MonadHold t m, MonadFix m, PostBuild t m) =>
  InputType ->
  Text ->
  Bool ->
  Text ->
  Text ->
  Bool ->
  Event t Bool ->
  Maybe Text ->
  m (Dynamic t Text)
inputWidget inputType label mandatory placeholder initialValue valid evValid mbHelp =
  el "div" $ do
    elAttr
      "label"
      ("class" =: "block mb-2 text-sm text-gray-900" <> "for" =: inputId)
      $ text inputLabel

    dyInput <- elClass "div" "relative" $ do
      rec dyInput <-
            value
              <$> inputElement
                ( def
                    & inputElementConfig_initialValue .~ initialValue
                    & initialAttributes
                      .~ ( "class" =: inputClasses' valid
                             <> "type" =: toText inputType
                             <> "placeholder" =: placeholder
                             <> "id" =: inputId
                         )
                    & modifyAttributes
                      .~ ( ((=:) "class" . Just . inputClasses' <$> evValid)
                             <> (toggleInputType inputType <$> evPasswordVisible)
                         )
                )
          evPasswordVisible <- elEye inputType
      pure dyInput

    elHelp mbHelp

    pure dyInput
  where
    inputClasses' = inputClasses inputType

    inputId = T.toLower label
    inputLabel = label <> if mandatory then " *" else ""

    toggleInputType MkText _ = mempty
    toggleInputType MkPassword True = "type" =: Just "text"
    toggleInputType MkPassword False = "type" =: Just "password"

    elEye MkText = pure never
    elEye MkPassword = do
      rec ev <- elClass
            "div"
            "absolute inset-y-0 right-0 pr-3 flex items-center"
            $ do
              (e, _) <- elDynClass' "i" (eyeClasses <$> dyPasswordVisible) blank
              pure $ domEvent Click e
          dyPasswordVisible <- toggle False ev
      pure $ updated dyPasswordVisible

    eyeClasses = T.unwords . ("fa-solid" :) . pure . eyeIcon

    eyeIcon True = "fa-eye-slash"
    eyeIcon False = "fa-eye"

    elHelp Nothing = pure ()
    elHelp (Just help) =
      elClass "p" "mt-2 text-sm text-gray-500" $
        text help

inputClasses :: InputType -> Bool -> Text
inputClasses inputType valid =
  T.unwords $
    [ "bg-gray-50",
      "border",
      "rounded-lg",
      "block",
      "w-full",
      "p-2.5"
    ]
      <> validClasses valid
      <> inputTypeClasses inputType
  where
    validClasses True =
      [ "border-gray-300",
        "text-gray-900",
        "focus:ring-blue-600",
        "focus:border-blue-600"
      ]
    validClasses False =
      [ "border-red-300",
        "text-red-900",
        "focus:ring-red-600",
        "focus:border-red-600"
      ]
    -- Make room for the eye icon
    inputTypeClasses MkPassword = ["pr-10"]
    inputTypeClasses MkText = mempty

buttonClasses :: Text
buttonClasses =
  T.unwords
    [ "w-full",
      "text-white",
      "bg-blue-600",
      "focus:ring-4",
      "focus:outline-none",
      "focus:ring-blue-300",
      "font-medium",
      "rounded-lg",
      "text-sm",
      "px-5",
      "py-2.5",
      "text-center",
      "disabled:opacity-50"
    ]
