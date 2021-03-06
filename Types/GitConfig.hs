{- git-annex configuration
 -
 - Copyright 2012-2015 Joey Hess <id@joeyh.name>
 -
 - Licensed under the GNU GPL version 3 or higher.
 -}

module Types.GitConfig ( 
	Configurable(..),
	GitConfig(..),
	extractGitConfig,
	mergeGitConfig,
	RemoteGitConfig(..),
	extractRemoteGitConfig,
	dummyRemoteGitConfig,
) where

import Common
import qualified Git
import qualified Git.Config
import qualified Git.Construct
import Git.Types
import Git.ConfigTypes
import Utility.DataUnits
import Config.Cost
import Types.UUID
import Types.Distribution
import Types.Availability
import Types.Concurrency
import Types.NumCopies
import Types.Difference
import Types.RefSpec
import Types.RepoVersion
import Config.DynamicConfig
import Utility.HumanTime
import Utility.Gpg (GpgCmd, mkGpgCmd)
import Utility.ThreadScheduler (Seconds(..))
import Utility.Url (Scheme, mkScheme)

import Control.Concurrent.STM
import qualified Data.Set as S

-- | A configurable value, that may not be fully determined yet because
-- the global git config has not yet been loaded.
data Configurable a
	= HasConfig a
	-- ^ Value is fully determined.
	| DefaultConfig a
	-- ^ A default value is known, but not all config sources
	-- have been read yet.
	deriving (Show)

{- Main git-annex settings. Each setting corresponds to a git-config key
 - such as annex.foo -}
data GitConfig = GitConfig
	{ annexVersion :: Maybe RepoVersion
	, annexUUID :: UUID
	, annexNumCopies :: Maybe NumCopies
	, annexDiskReserve :: Integer
	, annexDirect :: Bool
	, annexBackend :: Maybe String
	, annexQueueSize :: Maybe Int
	, annexBloomCapacity :: Maybe Int
	, annexBloomAccuracy :: Maybe Int
	, annexSshCaching :: Maybe Bool
	, annexAlwaysCommit :: Bool
	, annexCommitMessage :: Maybe String
	, annexMergeAnnexBranches :: Bool
	, annexDelayAdd :: Maybe Int
	, annexHttpHeaders :: [String]
	, annexHttpHeadersCommand :: Maybe String
	, annexAutoCommit :: Configurable Bool
	, annexResolveMerge :: Configurable Bool
	, annexSyncContent :: Configurable Bool
	, annexDebug :: Bool
	, annexWebOptions :: [String]
	, annexYoutubeDlOptions :: [String]
	, annexAriaTorrentOptions :: [String]
	, annexCrippledFileSystem :: Bool
	, annexLargeFiles :: Maybe String
	, annexAddSmallFiles :: Bool
	, annexFsckNudge :: Bool
	, annexAutoUpgrade :: AutoUpgrade
	, annexExpireUnused :: Maybe (Maybe Duration)
	, annexSecureEraseCommand :: Maybe String
	, annexGenMetaData :: Bool
	, annexListen :: Maybe String
	, annexStartupScan :: Bool
	, annexHardLink :: Bool
	, annexThin :: Bool
	, annexDifferences :: Differences
	, annexUsedRefSpec :: Maybe RefSpec
	, annexVerify :: Bool
	, annexPidLock :: Bool
	, annexPidLockTimeout :: Seconds
	, annexAddUnlocked :: Bool
	, annexSecureHashesOnly :: Bool
	, annexRetry :: Maybe Integer
	, annexRetryDelay :: Maybe Seconds
	, annexAllowedUrlSchemes :: S.Set Scheme
	, annexAllowedHttpAddresses :: String
	, annexAllowUnverifiedDownloads :: Bool
	, annexMaxExtensionLength :: Maybe Int
	, annexJobs :: Concurrency
	, coreSymlinks :: Bool
	, coreSharedRepository :: SharedRepository
	, receiveDenyCurrentBranch :: DenyCurrentBranch
	, gcryptId :: Maybe String
	, gpgCmd :: GpgCmd
	}

extractGitConfig :: Git.Repo -> GitConfig
extractGitConfig r = GitConfig
	{ annexVersion = RepoVersion <$> getmayberead (annex "version")
	, annexUUID = maybe NoUUID toUUID $ getmaybe (annex "uuid")
	, annexNumCopies = NumCopies <$> getmayberead (annex "numcopies")
	, annexDiskReserve = fromMaybe onemegabyte $
		readSize dataUnits =<< getmaybe (annex "diskreserve")
	, annexDirect = getbool (annex "direct") False
	, annexBackend = maybe
		-- annex.backends is the old name of the option, still used
		-- when annex.backend is not set.
		(headMaybe $ getwords (annex "backends"))
		Just
		(getmaybe (annex "backend"))
	, annexQueueSize = getmayberead (annex "queuesize")
	, annexBloomCapacity = getmayberead (annex "bloomcapacity")
	, annexBloomAccuracy = getmayberead (annex "bloomaccuracy")
	, annexSshCaching = getmaybebool (annex "sshcaching")
	, annexAlwaysCommit = getbool (annex "alwayscommit") True
	, annexCommitMessage = getmaybe (annex "commitmessage")
	, annexMergeAnnexBranches = getbool (annex "merge-annex-branches") True
	, annexDelayAdd = getmayberead (annex "delayadd")
	, annexHttpHeaders = getlist (annex "http-headers")
	, annexHttpHeadersCommand = getmaybe (annex "http-headers-command")
	, annexAutoCommit = configurable True $ 
		getmaybebool (annex "autocommit")
	, annexResolveMerge = configurable True $ 
		getmaybebool (annex "resolvemerge")
	, annexSyncContent = configurable False $ 
		getmaybebool (annex "synccontent")
	, annexDebug = getbool (annex "debug") False
	, annexWebOptions = getwords (annex "web-options")
	, annexYoutubeDlOptions = getwords (annex "youtube-dl-options")
	, annexAriaTorrentOptions = getwords (annex "aria-torrent-options")
	, annexCrippledFileSystem = getbool (annex "crippledfilesystem") False
	, annexLargeFiles = getmaybe (annex "largefiles")
	, annexAddSmallFiles = getbool (annex "addsmallfiles") True
	, annexFsckNudge = getbool (annex "fscknudge") True
	, annexAutoUpgrade = toAutoUpgrade $ getmaybe (annex "autoupgrade")
	, annexExpireUnused = maybe Nothing Just . parseDuration
		<$> getmaybe (annex "expireunused")
	, annexSecureEraseCommand = getmaybe (annex "secure-erase-command")
	, annexGenMetaData = getbool (annex "genmetadata") False
	, annexListen = getmaybe (annex "listen")
	, annexStartupScan = getbool (annex "startupscan") True
	, annexHardLink = getbool (annex "hardlink") False
	, annexThin = getbool (annex "thin") False
	, annexDifferences = getDifferences r
	, annexUsedRefSpec = either (const Nothing) Just . parseRefSpec 
		=<< getmaybe (annex "used-refspec")
	, annexVerify = getbool (annex "verify") True
	, annexPidLock = getbool (annex "pidlock") False
	, annexPidLockTimeout = Seconds $ fromMaybe 300 $
		getmayberead (annex "pidlocktimeout")
	, annexAddUnlocked = getbool (annex "addunlocked") False
	, annexSecureHashesOnly = getbool (annex "securehashesonly") False
	, annexRetry = getmayberead (annex "retry")
	, annexRetryDelay = Seconds
		<$> getmayberead (annex "retrydelay")
	, annexAllowedUrlSchemes = S.fromList $ map mkScheme $
		maybe ["http", "https", "ftp"] words $
			getmaybe (annex "security.allowed-url-schemes")
	, annexAllowedHttpAddresses = fromMaybe "" $
		getmaybe (annex "security.allowed-http-addresses")
	, annexAllowUnverifiedDownloads = (== Just "ACKTHPPT") $
		getmaybe (annex "security.allow-unverified-downloads")
	, annexMaxExtensionLength = getmayberead (annex "maxextensionlength")
	, annexJobs = maybe NonConcurrent Concurrent $ getmayberead (annex "jobs")
	, coreSymlinks = getbool "core.symlinks" True
	, coreSharedRepository = getSharedRepository r
	, receiveDenyCurrentBranch = getDenyCurrentBranch r
	, gcryptId = getmaybe "core.gcrypt-id"
	, gpgCmd = mkGpgCmd (getmaybe "gpg.program")
	}
  where
	getbool k d = fromMaybe d $ getmaybebool k
	getmaybebool k = Git.Config.isTrue =<< getmaybe k
	getmayberead k = readish =<< getmaybe k
	getmaybe k = Git.Config.getMaybe k r
	getlist k = Git.Config.getList k r
	getwords k = fromMaybe [] $ words <$> getmaybe k

	configurable d Nothing = DefaultConfig d
	configurable _ (Just v) = HasConfig v

	annex k = "annex." ++ k
			
	onemegabyte = 1000000

{- Merge a GitConfig that comes from git-config with one containing
 - repository-global defaults. -}
mergeGitConfig :: GitConfig -> GitConfig -> GitConfig
mergeGitConfig gitconfig repoglobals = gitconfig
	{ annexAutoCommit = merge annexAutoCommit
	, annexSyncContent = merge annexSyncContent
	}
  where
	merge f = case f gitconfig of
		HasConfig v -> HasConfig v
		DefaultConfig d -> case f repoglobals of
			HasConfig v -> HasConfig v
			DefaultConfig _ -> HasConfig d

{- Per-remote git-annex settings. Each setting corresponds to a git-config
 - key such as <remote>.annex-foo, or if that is not set, a default from
 - annex.foo.
 -
 - Note that this is from the perspective of the local repository,
 - it is not influenced in any way by the contents of the remote
 - repository's git config.
 -}
data RemoteGitConfig = RemoteGitConfig
	{ remoteAnnexCost :: DynamicConfig (Maybe Cost)
	, remoteAnnexIgnore :: DynamicConfig Bool
	, remoteAnnexSync :: DynamicConfig Bool
	, remoteAnnexPull :: Bool
	, remoteAnnexPush :: Bool
	, remoteAnnexReadOnly :: Bool
	, remoteAnnexVerify :: Bool
	, remoteAnnexCheckUUID :: Bool
	, remoteAnnexExportTracking :: Maybe Git.Ref
	, remoteAnnexTrustLevel :: Maybe String
	, remoteAnnexStartCommand :: Maybe String
	, remoteAnnexStopCommand :: Maybe String
	, remoteAnnexAvailability :: Maybe Availability
	, remoteAnnexSpeculatePresent :: Bool
	, remoteAnnexBare :: Maybe Bool
	, remoteAnnexRetry :: Maybe Integer
	, remoteAnnexRetryDelay :: Maybe Seconds
	, remoteAnnexAllowUnverifiedDownloads :: Bool

	{- These settings are specific to particular types of remotes
	 - including special remotes. -}
	, remoteAnnexShell :: Maybe String
	, remoteAnnexSshOptions :: [String]
	, remoteAnnexRsyncOptions :: [String]
	, remoteAnnexRsyncUploadOptions :: [String]
	, remoteAnnexRsyncDownloadOptions :: [String]
	, remoteAnnexRsyncTransport :: [String]
	, remoteAnnexGnupgOptions :: [String]
	, remoteAnnexGnupgDecryptOptions :: [String]
	, remoteAnnexRsyncUrl :: Maybe String
	, remoteAnnexBupRepo :: Maybe String
	, remoteAnnexTahoe :: Maybe FilePath
	, remoteAnnexBupSplitOptions :: [String]
	, remoteAnnexDirectory :: Maybe FilePath
	, remoteAnnexAndroidDirectory :: Maybe FilePath
	, remoteAnnexAndroidSerial :: Maybe String
	, remoteAnnexGCrypt :: Maybe String
	, remoteAnnexDdarRepo :: Maybe String
	, remoteAnnexHookType :: Maybe String
	, remoteAnnexExternalType :: Maybe String
	}

{- The Git.Repo is the local repository, which has the remote with the
 - given RemoteName. -}
extractRemoteGitConfig :: Git.Repo -> RemoteName -> STM RemoteGitConfig
extractRemoteGitConfig r remotename = do
	annexcost <- mkDynamicConfig readCommandRunner
		(notempty $ getmaybe "cost-command")
		(getmayberead "cost")
	annexignore <- mkDynamicConfig unsuccessfullCommandRunner
		(notempty $ getmaybe "ignore-command")
		(getbool "ignore" False)
	annexsync <- mkDynamicConfig successfullCommandRunner
		(notempty $ getmaybe "sync-command")
		(getbool "sync" True)
	return $ RemoteGitConfig
		{ remoteAnnexCost = annexcost
		, remoteAnnexIgnore = annexignore
		, remoteAnnexSync = annexsync
		, remoteAnnexPull = getbool "pull" True
		, remoteAnnexPush = getbool "push" True
		, remoteAnnexReadOnly = getbool "readonly" False
		, remoteAnnexCheckUUID = getbool "checkuuid" True
		, remoteAnnexVerify = getbool "verify" True
		, remoteAnnexExportTracking = Git.Ref
			<$> notempty (getmaybe "export-tracking")
		, remoteAnnexTrustLevel = notempty $ getmaybe "trustlevel"
		, remoteAnnexStartCommand = notempty $ getmaybe "start-command"
		, remoteAnnexStopCommand = notempty $ getmaybe "stop-command"
		, remoteAnnexAvailability = getmayberead "availability"
		, remoteAnnexSpeculatePresent = getbool "speculate-present" False
		, remoteAnnexBare = getmaybebool "bare"
		, remoteAnnexRetry = getmayberead "retry"
		, remoteAnnexRetryDelay = Seconds
			<$> getmayberead "retrydelay"
		, remoteAnnexAllowUnverifiedDownloads = (== Just "ACKTHPPT") $
			getmaybe ("security-allow-unverified-downloads")
		, remoteAnnexShell = getmaybe "shell"
		, remoteAnnexSshOptions = getoptions "ssh-options"
		, remoteAnnexRsyncOptions = getoptions "rsync-options"
		, remoteAnnexRsyncDownloadOptions = getoptions "rsync-download-options"
		, remoteAnnexRsyncUploadOptions = getoptions "rsync-upload-options"
		, remoteAnnexRsyncTransport = getoptions "rsync-transport"
		, remoteAnnexGnupgOptions = getoptions "gnupg-options"
		, remoteAnnexGnupgDecryptOptions = getoptions "gnupg-decrypt-options"
		, remoteAnnexRsyncUrl = notempty $ getmaybe "rsyncurl"
		, remoteAnnexBupRepo = getmaybe "buprepo"
		, remoteAnnexTahoe = getmaybe "tahoe"
		, remoteAnnexBupSplitOptions = getoptions "bup-split-options"
		, remoteAnnexDirectory = notempty $ getmaybe "directory"
		, remoteAnnexAndroidDirectory = notempty $ getmaybe "androiddirectory"
		, remoteAnnexAndroidSerial = notempty $ getmaybe "androidserial"
		, remoteAnnexGCrypt = notempty $ getmaybe "gcrypt"
		, remoteAnnexDdarRepo = getmaybe "ddarrepo"
		, remoteAnnexHookType = notempty $ getmaybe "hooktype"
		, remoteAnnexExternalType = notempty $ getmaybe "externaltype"
		}
  where
	getbool k d = fromMaybe d $ getmaybebool k
	getmaybebool k = Git.Config.isTrue =<< getmaybe k
	getmayberead k = readish =<< getmaybe k
	getmaybe k = mplus (Git.Config.getMaybe (key k) r)
		(Git.Config.getMaybe (remotekey k) r)
	getoptions k = fromMaybe [] $ words <$> getmaybe k

	key k = "annex." ++ k
	remotekey k = "remote." ++ remotename ++ ".annex-" ++ k

notempty :: Maybe String -> Maybe String	
notempty Nothing = Nothing
notempty (Just "") = Nothing
notempty (Just s) = Just s

dummyRemoteGitConfig :: IO RemoteGitConfig
dummyRemoteGitConfig = atomically $ 
	extractRemoteGitConfig Git.Construct.fromUnknown "dummy"
