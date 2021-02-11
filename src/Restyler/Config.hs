{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE TypeOperators #-}
{-# OPTIONS_HADDOCK prune, ignore-exports #-}

-- | Handling of @.restyled.yaml@ content and behavior driven there-by
--
-- __Implementation note__: This is a playground. I'm doing lots of HKD stuff
-- here that I would not normally subject my collaborators to.
--
-- 1. We only do this stuff here, and
-- 2. It should stay encapsulated away from the rest of the system
--
-- References:
--
-- - <https://reasonablypolymorphic.com/blog/higher-kinded-data/>
-- - <https://chrispenner.ca/posts/hkd-options>
-- - <https://hackage.haskell.org/package/barbies>
--
module Restyler.Config
    ( Config(..)
    , configPullRequestReviewer
    , loadConfig
    , HasConfig(..)
    , whenConfig
    , whenConfigNonEmpty
    , whenConfigJust

    -- * Exported for use in tests
    , ConfigSource(..)
    , loadConfigFrom
    , decodeEither
    , defaultConfigContent
    , configPaths
    )
where

import Restyler.Prelude

import Control.Monad.Trans.Maybe (MaybeT(..))
import Data.Aeson
import Data.Aeson.Casing
import qualified Data.ByteString.Char8 as C8
import Data.FileEmbed (embedFile)
import Data.Functor.Barbie
import Data.List (isInfixOf)
import qualified Data.List.NonEmpty as NE
import Data.Monoid (Alt(..))
import qualified Data.Set as Set
import qualified Data.Yaml as Yaml
import qualified Data.Yaml.Ext as Yaml
import GitHub.Data (IssueLabel, User)
import Restyler.App.Error
import Restyler.Capabilities.DownloadFile
import Restyler.Capabilities.Logger
import Restyler.Capabilities.System
import Restyler.CommitTemplate
import Restyler.Config.ChangedPaths
import Restyler.Config.ExpectedKeys
import Restyler.Config.Glob
import Restyler.Config.RequestReview
import Restyler.Config.Restyler
import Restyler.Config.SketchyList
import Restyler.Config.Statuses
import Restyler.PullRequest
import Restyler.RemoteFile
import Restyler.Restyler

-- | A polymorphic representation of @'Config'@
--
-- 1. The @f@ parameter can dictate if attributes are required (@'Identity'@) or
--    optional (@'Maybe'@), or optional with override semantics (@'Last'@)
--
-- 2. Any list keys use @'SketchyList'@ so users can type a single scalar
--    element or a list of many elements.
--
-- 3. The @Restylers@ attribute is a (sketchy) list of @'ConfigRestyler'@, which
--    is a function to apply to the later-fetched list of all Restylers.
--
-- See the various @resolve@ functions for how to get a real @'Config'@ out of
-- this beast.
--
data ConfigF f = ConfigF
    { cfEnabled :: f Bool
    , cfExclude :: f (SketchyList Glob)
    , cfChangedPaths :: f ChangedPathsConfig
    , cfAuto :: f Bool
    , cfCommitTemplate :: f CommitTemplate
    , cfRemoteFiles :: f (SketchyList RemoteFile)
    , cfPullRequests :: f Bool
    , cfComments :: f Bool
    , cfStatuses :: f Statuses
    , cfRequestReview :: f RequestReviewConfig
    , cfLabels :: f (SketchyList (Name IssueLabel))
    , cfIgnoreLabels :: f (SketchyList (Name IssueLabel))
    , cfRestylersVersion :: f String
    , cfRestylers :: f (SketchyList RestylerOverride)
    }
    deriving stock Generic
    deriving anyclass (FunctorB, ApplicativeB, ConstraintsB)

-- | An empty @'ConfigF'@ of all @'Nothing'@s
--
-- N.B. the choice of @'getAlt'@ is somewhat arbitrary. We just need a @Maybe@
-- wrapper @f a@ where @getX mempty@ is @Nothing@, but without a @Monoid a@
-- constraint.
--
emptyConfig :: ConfigF Maybe
emptyConfig = bmap getAlt bmempty

instance FromJSON (ConfigF Maybe) where
    parseJSON a@(Array _) = do
        restylers <- parseJSON a
        pure emptyConfig { cfRestylers = restylers }
    parseJSON v = genericParseJSONValidated (aesonPrefix snakeCase) v

instance FromJSON (ConfigF Identity) where
    parseJSON = genericParseJSON $ aesonPrefix snakeCase

-- | Fill out one @'ConfigF'@ from another
resolveConfig :: ConfigF Maybe -> ConfigF Identity -> ConfigF Identity
resolveConfig = bzipWith f
  where
    f :: Maybe a -> Identity a -> Identity a
    f ma ia = maybe ia Identity ma

-- | Fully resolved configuration
--
-- This is what we work with throughout the system.
--
data Config = Config
    { cEnabled :: Bool
    , cExclude :: [Glob]
    , cChangedPaths :: ChangedPathsConfig
    , cAuto :: Bool
    , cCommitTemplate :: CommitTemplate
    , cRemoteFiles :: [RemoteFile]
    , cPullRequests :: Bool
    , cComments :: Bool
    , cStatuses :: Statuses
    , cRequestReview :: RequestReviewConfig
    , cLabels :: Set (Name IssueLabel)
    , cIgnoreLabels :: Set (Name IssueLabel)
    , cRestylers :: [Restyler]
    }
    deriving stock (Eq, Show, Generic)

-- | If so configured, return the @'User'@ from whom to request review
configPullRequestReviewer :: PullRequest -> Config -> Maybe (Name User)
configPullRequestReviewer pr = determineReviewer pr . cRequestReview

instance ToJSON Config where
    toJSON = genericToJSON $ aesonPrefix snakeCase
    toEncoding = genericToEncoding $ aesonPrefix snakeCase

configErrorInvalidYaml :: ByteString -> Yaml.ParseException -> AppError
configErrorInvalidYaml yaml = ConfigErrorInvalidYaml yaml
    . Yaml.modifyYamlProblem modify
  where
    modify msg
        | isCannotStart msg && hasTabIndent yaml
        = msg
            <> "\n\nThis may be caused by your source file containing tabs."
            <> "\nYAML forbids tabs for indentation. See https://yaml.org/faq.html."
        | otherwise
        = msg
    isCannotStart = ("character that cannot start any token" `isInfixOf`)
    hasTabIndent = ("\n\t" `C8.isInfixOf`)

-- | Load a fully-inflated @'Config'@
--
-- Read any @.restyled.yaml@, fill it out from defaults, grab the versioned set
-- of restylers data, and apply the configured choices and overrides.
--
loadConfig
    :: ( MonadError AppError m
       , MonadLogger m
       , MonadSystem m
       , MonadDownloadFile m
       )
    => m Config
loadConfig = loadConfigFrom $ map ConfigPath configPaths

loadConfigFrom
    :: ( MonadError AppError m
       , MonadLogger m
       , MonadSystem m
       , MonadDownloadFile m
       )
    => [ConfigSource]
    -> m Config
loadConfigFrom sources = do
    config <- loadConfigF sources
    restylers <- loadRestylers config
    logDebug $ displayYaml "Restylers:\n" restylers
    x <- resolveRestylers config restylers
    x <$ logDebug (displayYaml "Configuration\n:" x)

loadRestylers
    :: (MonadError AppError m, MonadSystem m, MonadDownloadFile m)
    => ConfigF Identity
    -> m [Restyler]
loadRestylers =
    either (throwError . ConfigErrorInvalidRestylersYaml) pure
        <=< getAllRestylersVersioned
        . runIdentity
        . cfRestylersVersion

getAllRestylersVersioned
    :: (MonadSystem m, MonadDownloadFile m)
    => String
    -> m (Either Yaml.ParseException [Restyler])
getAllRestylersVersioned version = do
    downloadRemoteFile restylers
    Yaml.decodeEither' <$> readFileBS (rfPath restylers)
  where
    restylers = RemoteFile
        { rfUrl = URL $ pack $ restylersYamlUrl version
        , rfPath = "/tmp/restylers-" <> version <> ".yaml"
        }

restylersYamlUrl :: String -> String
restylersYamlUrl version =
    "https://docs.restyled.io/data-files/restylers/manifests/"
        <> version
        <> "/restylers.yaml"

data ConfigSource
    = ConfigPath FilePath
    | ConfigContent ByteString

readConfigSources :: MonadSystem m => [ConfigSource] -> m (Maybe ByteString)
readConfigSources = runMaybeT . asum . fmap (MaybeT . go)
  where
    go :: MonadSystem m => ConfigSource -> m (Maybe ByteString)
    go = \case
        ConfigPath path -> do
            exists <- doesFileExist path
            if exists then Just <$> readFileBS path else pure Nothing
        ConfigContent content -> pure $ Just content

-- | Load configuration if present and apply defaults
--
-- Returns @'ConfigF' 'Identity'@ because defaulting has populated all fields.
--
loadConfigF
    :: (MonadSystem m, MonadError AppError m)
    => [ConfigSource]
    -> m (ConfigF Identity)
loadConfigF sources = do
    resolveConfig
        <$> loadUserConfigF sources
        <*> decodeEither defaultConfigContent

loadUserConfigF
    :: (MonadSystem m, MonadError AppError m)
    => [ConfigSource]
    -> m (ConfigF Maybe)
loadUserConfigF = maybeM (pure emptyConfig) decodeEither . readConfigSources

decodeEither :: (MonadError AppError m, FromJSON a) => ByteString -> m a
decodeEither content =
    either (throwError . configErrorInvalidYaml content) pure
        $ Yaml.decodeEither' content

-- | Populate @'cRestylers'@ using the versioned restylers data
--
-- May throw @'ConfigErrorInvalidRestylers'@.
--
resolveRestylers
    :: MonadError AppError m => ConfigF Identity -> [Restyler] -> m Config
resolveRestylers ConfigF {..} allRestylers = do
    restylers <-
        either (throwError . ConfigErrorInvalidRestylers) pure
        $ overrideRestylers allRestylers
        $ unSketchy
        $ runIdentity cfRestylers

    pure Config
        { cEnabled = runIdentity cfEnabled
        , cExclude = unSketchy $ runIdentity cfExclude
        , cChangedPaths = runIdentity cfChangedPaths
        , cAuto = runIdentity cfAuto
        , cCommitTemplate = runIdentity cfCommitTemplate
        , cRemoteFiles = unSketchy $ runIdentity cfRemoteFiles
        , cPullRequests = runIdentity cfPullRequests
        , cComments = runIdentity cfComments
        , cStatuses = runIdentity cfStatuses
        , cRequestReview = runIdentity cfRequestReview
        , cLabels = Set.fromList $ unSketchy $ runIdentity cfLabels
        , cIgnoreLabels = Set.fromList $ unSketchy $ runIdentity cfIgnoreLabels
        , cRestylers = restylers
        }

class HasConfig env where
    configL :: Lens' env Config

whenConfig
    :: (MonadReader env m, HasConfig env) => (Config -> Bool) -> m () -> m ()
whenConfig check act =
    whenConfigJust (bool Nothing (Just ()) . check) (const act)

whenConfigNonEmpty
    :: (MonadReader env m, HasConfig env)
    => (Config -> [a])
    -> ([a] -> m ())
    -> m ()
whenConfigNonEmpty check act =
    whenConfigJust (NE.nonEmpty . check) (act . NE.toList)

whenConfigJust
    :: (MonadReader env m, HasConfig env)
    => (Config -> Maybe a)
    -> (a -> m ())
    -> m ()
whenConfigJust check act = traverse_ act . check =<< view configL

defaultConfigContent :: ByteString
defaultConfigContent = $(embedFile "config/default.yaml")

configPaths :: [FilePath]
configPaths =
    [ ".restyled.yaml"
    , ".restyled.yml"
    , ".github/restyled.yaml"
    , ".github/restyled.yml"
    ]

displayYaml :: ToJSON a => Utf8Builder -> a -> Utf8Builder
displayYaml prefix = (prefix <>) . display . decodeUtf8 . Yaml.encode
