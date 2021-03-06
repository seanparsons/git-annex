{- S3 remotes
 -
 - Copyright 2011-2018 Joey Hess <id@joeyh.name>
 -
 - Licensed under the GNU GPL version 3 or higher.
 -}

{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE CPP #-}

module Remote.S3 (remote, iaHost, configIA, iaItemUrl) where

import qualified Aws as AWS
import qualified Aws.Core as AWS
import qualified Aws.S3 as S3
import qualified Data.Text as T
import qualified Data.Text.Encoding as T
import qualified Data.ByteString.Lazy as L
import qualified Data.ByteString as BS
import qualified Data.Map as M
import qualified Data.Set as S
import qualified System.FilePath.Posix as Posix
import Data.Char
import Network.Socket (HostName)
import Network.HTTP.Conduit (Manager)
import Network.HTTP.Client (responseStatus, responseBody, RequestBody(..))
import Network.HTTP.Types
import Control.Monad.Trans.Resource
import Control.Monad.Catch
import Data.IORef
import System.Log.Logger

import Annex.Common
import Types.Remote
import Types.Export
import Annex.Export
import qualified Git
import Config
import Config.Cost
import Remote.Helper.Special
import Remote.Helper.Http
import Remote.Helper.Messages
import Remote.Helper.Export
import qualified Remote.Helper.AWS as AWS
import Creds
import Annex.UUID
import Logs.Web
import Logs.MetaData
import Types.MetaData
import Utility.Metered
import qualified Annex.Url as Url
import Utility.DataUnits
import Utility.FileSystemEncoding
import Annex.Content
import Annex.Url (withUrlOptions)
import Utility.Url (checkBoth, UrlOptions(..))
import Utility.Env

type BucketName = String
type BucketObject = String

remote :: RemoteType
remote = RemoteType
	{ typename = "S3"
	, enumerate = const (findSpecialRemotes "s3")
	, generate = gen
	, setup = s3Setup
	, exportSupported = exportIsSupported
	}

gen :: Git.Repo -> UUID -> RemoteConfig -> RemoteGitConfig -> Annex (Maybe Remote)
gen r u c gc = do
	cst <- remoteCost gc expensiveRemoteCost
	info <- extractS3Info c
	return $ new cst info
  where
	new cst info = Just $ specialRemote c
		(prepareS3Handle this $ store this info)
		(prepareS3HandleMaybe this $ retrieve this c info)
		(prepareS3Handle this $ remove info)
		(prepareS3HandleMaybe this $ checkKey this c info)
		this
	  where
		this = Remote
			{ uuid = u
			, cost = cst
			, name = Git.repoDescribe r
			, storeKey = storeKeyDummy
			, retrieveKeyFile = retreiveKeyFileDummy
			, retrieveKeyFileCheap = retrieveCheap
			-- HttpManagerRestricted is used here, so this is
			-- secure.
			, retrievalSecurityPolicy = RetrievalAllKeysSecure
			, removeKey = removeKeyDummy
			, lockContent = Nothing
			, checkPresent = checkPresentDummy
			, checkPresentCheap = False
			, exportActions = withS3HandleMaybe c gc u $ \mh -> 
				return $ ExportActions
					{ storeExport = storeExportS3 u info mh
					, retrieveExport = retrieveExportS3 u info mh
					, removeExport = removeExportS3 u info mh
					, checkPresentExport = checkPresentExportS3 u info mh
					-- S3 does not have directories.
					, removeExportDirectory = Nothing
					, renameExport = renameExportS3 u info mh
					}
			, whereisKey = Just (getPublicWebUrls u info c)
			, remoteFsck = Nothing
			, repairRepo = Nothing
			, config = c
			, getRepo = return r
			, gitconfig = gc
			, localpath = Nothing
			, readonly = False
			, appendonly = versioning info
			, availability = GloballyAvailable
			, remotetype = remote
			, mkUnavailable = gen r u (M.insert "host" "!dne!" c) gc
			, getInfo = includeCredsInfo c (AWS.creds u) (s3Info c info)
			, claimUrl = Nothing
			, checkUrl = Nothing
			}

s3Setup :: SetupStage -> Maybe UUID -> Maybe CredPair -> RemoteConfig -> RemoteGitConfig -> Annex (RemoteConfig, UUID)
s3Setup ss mu mcreds c gc = do
	u <- maybe (liftIO genUUID) return mu
	s3Setup' ss u mcreds c gc

s3Setup' :: SetupStage -> UUID -> Maybe CredPair -> RemoteConfig -> RemoteGitConfig -> Annex (RemoteConfig, UUID)
s3Setup' ss u mcreds c gc
	| configIA c = archiveorg
	| otherwise = defaulthost
  where
	remotename = fromJust (M.lookup "name" c)
	defbucket = remotename ++ "-" ++ fromUUID u
	defaults = M.fromList
		[ ("datacenter", T.unpack $ AWS.defaultRegion AWS.S3)
		, ("storageclass", "STANDARD")
		, ("host", AWS.s3DefaultHost)
		, ("port", "80")
		, ("bucket", defbucket)
		]
		
	use fullconfig = do
		gitConfigSpecialRemote u fullconfig [("s3", "true")]
		return (fullconfig, u)

	defaulthost = do
		(c', encsetup) <- encryptionSetup c gc
		c'' <- setRemoteCredPair encsetup c' gc (AWS.creds u) mcreds
		let fullconfig = c'' `M.union` defaults
		case ss of
			Init -> genBucket fullconfig gc u
			_ -> return ()
		use fullconfig

	archiveorg = do
		showNote "Internet Archive mode"
		c' <- setRemoteCredPair noEncryptionUsed c gc (AWS.creds u) mcreds
		-- Ensure user enters a valid bucket name, since
		-- this determines the name of the archive.org item.
		let validbucket = replace " " "-" $
			fromMaybe (giveup "specify bucket=") $
				getBucketName c'
		let archiveconfig = 
			-- IA acdepts x-amz-* as an alias for x-archive-*
			M.mapKeys (replace "x-archive-" "x-amz-") $
			-- encryption does not make sense here
			M.insert "encryption" "none" $
			M.insert "bucket" validbucket $
			M.union c' $
			-- special constraints on key names
			M.insert "mungekeys" "ia" defaults
		info <- extractS3Info archiveconfig
		withS3Handle archiveconfig gc u $
			writeUUIDFile archiveconfig u info
		use archiveconfig

-- Sets up a http connection manager for S3 endpoint, which allows
-- http connections to be reused across calls to the helper.
prepareS3Handle :: Remote -> (S3Handle -> helper) -> Preparer helper
prepareS3Handle r = resourcePrepare $ const $
	withS3Handle (config r) (gitconfig r) (uuid r)

-- Allows for read-only actions, which can be run without a S3Handle.
prepareS3HandleMaybe :: Remote -> (Maybe S3Handle -> helper) -> Preparer helper
prepareS3HandleMaybe r = resourcePrepare $ const $
	withS3HandleMaybe (config r) (gitconfig r) (uuid r)

store :: Remote -> S3Info -> S3Handle -> Storer
store _r info h = fileStorer $ \k f p -> do
	void $ storeHelper info h f (T.pack $ bucketObject info k) p
	-- Store public URL to item in Internet Archive.
	when (isIA info && not (isChunkKey k)) $
		setUrlPresent k (iaPublicUrl info (bucketObject info k))
	return True

storeHelper :: S3Info -> S3Handle -> FilePath -> S3.Object -> MeterUpdate -> Annex (Maybe S3VersionID)
storeHelper info h f object p = case partSize info of
	Just partsz | partsz > 0 -> do
		fsz <- liftIO $ getFileSize f
		if fsz > partsz
			then multipartupload fsz partsz
			else singlepartupload
	_ -> singlepartupload
  where
	singlepartupload = do
		rbody <- liftIO $ httpBodyStorer f p
		r <- sendS3Handle h $ putObject info object rbody
		return (mkS3VersionID object (S3.porVersionId r))
	multipartupload fsz partsz = do
#if MIN_VERSION_aws(0,16,0)
		let startreq = (S3.postInitiateMultipartUpload (bucket info) object)
				{ S3.imuStorageClass = Just (storageClass info)
				, S3.imuMetadata = metaHeaders info
				, S3.imuAutoMakeBucket = isIA info
				, S3.imuExpires = Nothing -- TODO set some reasonable expiry
				}
		uploadid <- S3.imurUploadId <$> sendS3Handle h startreq

		-- The actual part size will be a even multiple of the
		-- 32k chunk size that lazy ByteStrings use.
		let partsz' = (partsz `div` toInteger defaultChunkSize) * toInteger defaultChunkSize

		-- Send parts of the file, taking care to stream each part
		-- w/o buffering in memory, since the parts can be large.
		etags <- bracketIO (openBinaryFile f ReadMode) hClose $ \fh -> do
			let sendparts meter etags partnum = do
				pos <- liftIO $ hTell fh
				if pos >= fsz
					then return (reverse etags)
					else do
						-- Calculate size of part that will
						-- be read.
						let sz = if fsz - pos < partsz'
							then fsz - pos
							else partsz'
						let p' = offsetMeterUpdate p (toBytesProcessed pos)
						let numchunks = ceiling (fromIntegral sz / fromIntegral defaultChunkSize :: Double)
						let popper = handlePopper numchunks defaultChunkSize p' fh
						let req = S3.uploadPart (bucket info) object partnum uploadid $
							 RequestBodyStream (fromIntegral sz) popper
						S3.UploadPartResponse { S3.uprETag = etag } <- sendS3Handle h req
						sendparts (offsetMeterUpdate meter (toBytesProcessed sz)) (etag:etags) (partnum + 1)
			sendparts p [] 1

		r <- sendS3Handle h $ S3.postCompleteMultipartUpload
			(bucket info) object uploadid (zip [1..] etags)
		return (mkS3VersionID object (S3.cmurVersionId r))
#else
		warning $ "Cannot do multipart upload (partsize " ++ show partsz ++ ") of large file (" ++ show fsz ++ "); built with too old a version of the aws library."
		singlepartupload
#endif

{- Implemented as a fileRetriever, that uses conduit to stream the chunks
 - out to the file. Would be better to implement a byteRetriever, but
 - that is difficult. -}
retrieve :: Remote -> RemoteConfig -> S3Info -> Maybe S3Handle -> Retriever
retrieve r _ info (Just h) = fileRetriever $ \f k p -> do
	loc <- eitherS3VersionID info (uuid r) k (T.pack $ bucketObject info k)
	retrieveHelper info h loc f p
retrieve r c info Nothing = fileRetriever $ \f k p ->
	getPublicWebUrls (uuid r) info c k >>= \case
		[] -> do
			needS3Creds (uuid r)
			giveup "No S3 credentials configured"
		us -> unlessM (downloadUrl k p us f) $
			giveup "failed to download content"

retrieveHelper :: S3Info -> S3Handle -> (Either S3.Object S3VersionID) -> FilePath -> MeterUpdate -> Annex ()
retrieveHelper info h loc f p = liftIO $ runResourceT $ do
	let req = case loc of
		Left o -> S3.getObject (bucket info) o
		Right (S3VersionID o vid) -> (S3.getObject (bucket info) o)
			{ S3.goVersionId = Just (T.pack vid) }
	S3.GetObjectResponse { S3.gorResponse = rsp } <- sendS3Handle' h req
	Url.sinkResponseFile p zeroBytesProcessed f WriteMode rsp

retrieveCheap :: Key -> AssociatedFile -> FilePath -> Annex Bool
retrieveCheap _ _ _ = return False

{- Internet Archive doesn't easily allow removing content.
 - While it may remove the file, there are generally other files
 - derived from it that it does not remove. -}
remove :: S3Info -> S3Handle -> Remover
remove info h k = do
	res <- tryNonAsync $ sendS3Handle h $
		S3.DeleteObject (T.pack $ bucketObject info k) (bucket info)
	return $ either (const False) (const True) res

checkKey :: Remote -> RemoteConfig -> S3Info -> Maybe S3Handle -> CheckPresent
checkKey r _ info (Just h) k = do
	showChecking r
	loc <- eitherS3VersionID info (uuid r) k (T.pack $ bucketObject info k)
	checkKeyHelper info h loc
checkKey r c info Nothing k = 
	getPublicWebUrls (uuid r) info c k >>= \case
		[] -> do
			needS3Creds (uuid r)
			giveup "No S3 credentials configured"
		us -> do
			showChecking r
			let check u = withUrlOptions $ 
				liftIO . checkBoth u (keySize k)
			anyM check us

checkKeyHelper :: S3Info -> S3Handle -> (Either S3.Object S3VersionID) -> Annex Bool
checkKeyHelper info h loc = do
#if MIN_VERSION_aws(0,10,0)
	rsp <- go
	return (isJust $ S3.horMetadata rsp)
#else
	catchMissingException $ do
		void go
		return True
#endif
  where
	go = sendS3Handle h req
	req = case loc of
		Left o -> S3.headObject (bucket info) o
		Right (S3VersionID o vid) -> (S3.headObject (bucket info) o)
			{ S3.hoVersionId = Just (T.pack vid) }

#if ! MIN_VERSION_aws(0,10,0)
	{- Catch exception headObject returns when an object is not present
	 - in the bucket, and returns False. All other exceptions indicate a
	 - check error and are let through. -}
	catchMissingException :: Annex Bool -> Annex Bool
	catchMissingException a = catchJust missing a (const $ return False)
	  where
		missing :: AWS.HeaderException -> Maybe ()
		missing e
			| AWS.headerErrorMessage e == "ETag missing" = Just ()
			| otherwise = Nothing
#endif

storeExportS3 :: UUID -> S3Info -> Maybe S3Handle -> FilePath -> Key -> ExportLocation -> MeterUpdate -> Annex Bool
storeExportS3 u info (Just h) f k loc p = 
	catchNonAsync go (\e -> warning (show e) >> return False)
  where
	go = do
		let o = T.pack $ bucketExportLocation info loc
		storeHelper info h f o p
			>>= setS3VersionID info u k
		return True
storeExportS3 u _ Nothing _ _ _ _ = do
	needS3Creds u
	return False

retrieveExportS3 :: UUID -> S3Info -> Maybe S3Handle -> Key -> ExportLocation -> FilePath -> MeterUpdate -> Annex Bool
retrieveExportS3 u info mh _k loc f p =
	catchNonAsync go (\e -> warning (show e) >> return False)
  where
	go = case mh of
		Just h -> do
			retrieveHelper info h (Left (T.pack exporturl)) f p
			return True
		Nothing -> case getPublicUrlMaker info of
			Nothing -> do
				needS3Creds u
				return False
			Just geturl -> Url.withUrlOptions $ 
				liftIO . Url.download p (geturl exporturl) f
	exporturl = bucketExportLocation info loc

removeExportS3 :: UUID -> S3Info -> Maybe S3Handle -> Key -> ExportLocation -> Annex Bool
removeExportS3 _u info (Just h) _k loc = 
	catchNonAsync go (\e -> warning (show e) >> return False)
  where
	go = do
		res <- tryNonAsync $ sendS3Handle h $
			S3.DeleteObject (T.pack $ bucketExportLocation info loc) (bucket info)
		return $ either (const False) (const True) res
removeExportS3 u _ Nothing _ _ = do
	needS3Creds u
	return False

checkPresentExportS3 :: UUID -> S3Info -> Maybe S3Handle -> Key -> ExportLocation -> Annex Bool
checkPresentExportS3 _u info (Just h) _k loc =
	checkKeyHelper info h (Left (T.pack $ bucketExportLocation info loc))
checkPresentExportS3 u info Nothing k loc = case getPublicUrlMaker info of
	Nothing -> do
		needS3Creds u
		giveup "No S3 credentials configured"
	Just geturl -> withUrlOptions $ liftIO . 
		checkBoth (geturl $ bucketExportLocation info loc) (keySize k)

-- S3 has no move primitive; copy and delete.
renameExportS3 :: UUID -> S3Info -> Maybe S3Handle -> Key -> ExportLocation -> ExportLocation -> Annex Bool
renameExportS3 _u info (Just h) _k src dest = catchNonAsync go (\_ -> return False)
  where
	go = do
		let co = S3.copyObject (bucket info) dstobject
			(S3.ObjectId (bucket info) srcobject Nothing)
			S3.CopyMetadata
		-- ACL is not preserved by copy.
		void $ sendS3Handle h $ co { S3.coAcl = acl info }
		void $ sendS3Handle h $ S3.DeleteObject srcobject (bucket info)
		return True
	srcobject = T.pack $ bucketExportLocation info src
	dstobject = T.pack $ bucketExportLocation info dest
renameExportS3 u _ Nothing _ _ _ = do
	needS3Creds u
	return False

{- Generate the bucket if it does not already exist, including creating the
 - UUID file within the bucket.
 -
 - Some ACLs can allow read/write to buckets, but not querying them,
 - so first check if the UUID file already exists and we can skip doing
 - anything.
 -}
genBucket :: RemoteConfig -> RemoteGitConfig -> UUID -> Annex ()
genBucket c gc u = do
	showAction "checking bucket"
	info <- extractS3Info c
	withS3Handle c gc u $ \h ->
		go info h =<< checkUUIDFile c u info h
  where
	go _ _ (Right True) = noop
	go info h _ = do
		v <- tryNonAsync $ sendS3Handle h (S3.getBucket $ bucket info)
		case v of
			Right _ -> noop
			Left _ -> do
				showAction $ "creating bucket in " ++ datacenter
				void $ sendS3Handle h $ S3.PutBucket
					(bucket info)
					(acl info)
					locconstraint
#if MIN_VERSION_aws(0,13,0)
					storageclass
#endif
		writeUUIDFile c u info h
	
	locconstraint = mkLocationConstraint $ T.pack datacenter
	datacenter = fromJust $ M.lookup "datacenter" c
#if MIN_VERSION_aws(0,13,0)
	-- "NEARLINE" as a storage class when creating a bucket is a
	-- nonstandard extension of Google Cloud Storage.
	storageclass = case getStorageClass c of
		sc@(S3.OtherStorageClass "NEARLINE") -> Just sc
		_ -> Nothing
#endif

{- Writes the UUID to an annex-uuid file within the bucket.
 -
 - If the file already exists in the bucket, it must match,
 - or this fails.
 -
 - Note that IA buckets can only created by having a file
 - stored in them. So this also takes care of that.
 -}
writeUUIDFile :: RemoteConfig -> UUID -> S3Info -> S3Handle -> Annex ()
writeUUIDFile c u info h = do
	v <- checkUUIDFile c u info h
	case v of
		Right True -> noop
		Right False -> do
			warning "The bucket already exists, and its annex-uuid file indicates it is used by a different special remote."
			giveup "Cannot reuse this bucket."
		_ -> void $ sendS3Handle h mkobject
  where
	file = T.pack $ uuidFile c
	uuidb = L.fromChunks [T.encodeUtf8 $ T.pack $ fromUUID u]

	mkobject = putObject info file (RequestBodyLBS uuidb)

{- Checks if the UUID file exists in the bucket
 - and has the specified UUID already. -}
checkUUIDFile :: RemoteConfig -> UUID -> S3Info -> S3Handle -> Annex (Either SomeException Bool)
checkUUIDFile c u info h = tryNonAsync $ liftIO $ runResourceT $ do
	resp <- tryS3 $ sendS3Handle' h (S3.getObject (bucket info) file)
	case resp of
		Left _ -> return False
		Right r -> do
			v <- AWS.loadToMemory r
			let !ok = check v
			return ok
  where
	check (S3.GetObjectMemoryResponse _meta rsp) =
		responseStatus rsp == ok200 && responseBody rsp == uuidb

	file = T.pack $ uuidFile c
	uuidb = L.fromChunks [T.encodeUtf8 $ T.pack $ fromUUID u]

uuidFile :: RemoteConfig -> FilePath
uuidFile c = getFilePrefix c ++ "annex-uuid"

tryS3 :: ResourceT IO a -> ResourceT IO (Either S3.S3Error a)
tryS3 a = (Right <$> a) `catch` (pure . Left)

data S3Handle = S3Handle 
	{ hmanager :: Manager
	, hawscfg :: AWS.Configuration
	, hs3cfg :: S3.S3Configuration AWS.NormalQuery
	}

{- Sends a request to S3 and gets back the response.
 - 
 - Note that pureAws's use of ResourceT is bypassed here;
 - the response should be fully processed while the S3Handle
 - is still open, eg within a call to withS3Handle.
 -}
sendS3Handle
	:: (AWS.Transaction req res, AWS.ServiceConfiguration req ~ S3.S3Configuration)
	=> S3Handle 
	-> req
	-> Annex res
sendS3Handle h r = liftIO $ runResourceT $ sendS3Handle' h r

sendS3Handle'
	:: (AWS.Transaction r a, AWS.ServiceConfiguration r ~ S3.S3Configuration)
	=> S3Handle
	-> r
	-> ResourceT IO a
sendS3Handle' h r = AWS.pureAws (hawscfg h) (hs3cfg h) (hmanager h) r

withS3Handle :: RemoteConfig -> RemoteGitConfig -> UUID -> (S3Handle -> Annex a) -> Annex a
withS3Handle c gc u a = withS3HandleMaybe c gc u $ \mh -> case mh of
	Just h -> a h
	Nothing -> do
		needS3Creds u
		giveup "No S3 credentials configured"

withS3HandleMaybe :: RemoteConfig -> RemoteGitConfig -> UUID -> (Maybe S3Handle -> Annex a) -> Annex a
withS3HandleMaybe c gc u a = do
	mcreds <- getRemoteCredPair c gc (AWS.creds u)
	case mcreds of
		Just creds -> do
			awscreds <- liftIO $ genCredentials creds
			let awscfg = AWS.Configuration AWS.Timestamp awscreds debugMapper
#if MIN_VERSION_aws(0,17,0)
				Nothing
#endif
			withUrlOptions $ \ou ->
				a $ Just $ S3Handle (httpManager ou) awscfg s3cfg
		Nothing -> a Nothing
  where
	s3cfg = s3Configuration c

needS3Creds :: UUID -> Annex ()
needS3Creds u = warnMissingCredPairFor "S3" (AWS.creds u)

s3Configuration :: RemoteConfig -> S3.S3Configuration AWS.NormalQuery
s3Configuration c = cfg
	{ S3.s3Port = port
	, S3.s3RequestStyle = case M.lookup "requeststyle" c of
		Just "path" -> S3.PathStyle
		Just s -> giveup $ "bad S3 requeststyle value: " ++ s
		Nothing -> S3.s3RequestStyle cfg
	}
  where
	proto
		| port == 443 = AWS.HTTPS
		| otherwise = AWS.HTTP
	h = fromJust $ M.lookup "host" c
	datacenter = fromJust $ M.lookup "datacenter" c
	-- When the default S3 host is configured, connect directly to
	-- the S3 endpoint for the configured datacenter.
	-- When another host is configured, it's used as-is.
	endpoint
		| h == AWS.s3DefaultHost = AWS.s3HostName $ T.pack datacenter
		| otherwise = T.encodeUtf8 $ T.pack h
	port = let s = fromJust $ M.lookup "port" c in
		case reads s of
		[(p, _)] -> p
		_ -> giveup $ "bad S3 port value: " ++ s
	cfg = S3.s3 proto endpoint False

data S3Info = S3Info
	{ bucket :: S3.Bucket
	, storageClass :: S3.StorageClass
	, bucketObject :: Key -> BucketObject
	, bucketExportLocation :: ExportLocation -> BucketObject
	, metaHeaders :: [(T.Text, T.Text)]
	, partSize :: Maybe Integer
	, isIA :: Bool
	, versioning :: Bool
	, public :: Bool
	, publicurl :: Maybe URLString
	, host :: Maybe String
	}

extractS3Info :: RemoteConfig -> Annex S3Info
extractS3Info c = do
	b <- maybe
		(giveup "S3 bucket not configured")
		(return . T.pack)
		(getBucketName c)
	return $ S3Info
		{ bucket = b
		, storageClass = getStorageClass c
		, bucketObject = getBucketObject c
		, bucketExportLocation = getBucketExportLocation c
		, metaHeaders = getMetaHeaders c
		, partSize = getPartSize c
		, isIA = configIA c
		, versioning = boolcfg "versioning"
		, public = boolcfg "public"
		, publicurl = M.lookup "publicurl" c
		, host = M.lookup "host" c
		}
  where
	boolcfg k = fromMaybe False $ yesNo =<< M.lookup k c

putObject :: S3Info -> T.Text -> RequestBody -> S3.PutObject
putObject info file rbody = (S3.putObject (bucket info) file rbody)
	{ S3.poStorageClass = Just (storageClass info)
	, S3.poMetadata = metaHeaders info
	, S3.poAutoMakeBucket = isIA info
	, S3.poAcl = acl info
	}

acl :: S3Info -> Maybe S3.CannedAcl
acl info
	| public info = Just S3.AclPublicRead
	| otherwise = Nothing

getBucketName :: RemoteConfig -> Maybe BucketName
getBucketName = map toLower <$$> M.lookup "bucket"

getStorageClass :: RemoteConfig -> S3.StorageClass
getStorageClass c = case M.lookup "storageclass" c of
	Just "REDUCED_REDUNDANCY" -> S3.ReducedRedundancy
#if MIN_VERSION_aws(0,13,0)
	Just s -> S3.OtherStorageClass (T.pack s)
#endif
	_ -> S3.Standard

getPartSize :: RemoteConfig -> Maybe Integer
getPartSize c = readSize dataUnits =<< M.lookup "partsize" c

getMetaHeaders :: RemoteConfig -> [(T.Text, T.Text)]
getMetaHeaders = map munge . filter ismetaheader . M.assocs
  where
	ismetaheader (h, _) = metaprefix `isPrefixOf` h
	metaprefix = "x-amz-meta-"
	metaprefixlen = length metaprefix
	munge (k, v) = (T.pack $ drop metaprefixlen k, T.pack v)

getFilePrefix :: RemoteConfig -> String
getFilePrefix = M.findWithDefault "" "fileprefix"

getBucketObject :: RemoteConfig -> Key -> BucketObject
getBucketObject c = munge . key2file
  where
	munge s = case M.lookup "mungekeys" c of
		Just "ia" -> iaMunge $ getFilePrefix c ++ s
		_ -> getFilePrefix c ++ s

getBucketExportLocation :: RemoteConfig -> ExportLocation -> BucketObject
getBucketExportLocation c loc = getFilePrefix c ++ fromExportLocation loc

{- Internet Archive documentation limits filenames to a subset of ascii.
 - While other characters seem to work now, this entity encodes everything
 - else to avoid problems. -}
iaMunge :: String -> String
iaMunge = (>>= munge)
  where
	munge c
		| isAsciiUpper c || isAsciiLower c || isNumber c = [c]
		| c `elem` ("_-.\"" :: String) = [c]
		| isSpace c = []
		| otherwise = "&" ++ show (ord c) ++ ";"

configIA :: RemoteConfig -> Bool
configIA = maybe False isIAHost . M.lookup "host"

{- Hostname to use for archive.org S3. -}
iaHost :: HostName
iaHost = "s3.us.archive.org"

isIAHost :: HostName -> Bool
isIAHost h = ".archive.org" `isSuffixOf` map toLower h

iaItemUrl :: BucketName -> URLString
iaItemUrl b = "http://archive.org/details/" ++ b

iaPublicUrl :: S3Info -> BucketObject -> URLString
iaPublicUrl info = genericPublicUrl $
	"http://archive.org/download/" ++ T.unpack (bucket info) ++ "/" 

awsPublicUrl :: S3Info -> BucketObject -> URLString
awsPublicUrl info = genericPublicUrl $ 
	"https://" ++ T.unpack (bucket info) ++ ".s3.amazonaws.com/" 

genericPublicUrl :: URLString -> BucketObject -> URLString
genericPublicUrl baseurl p = baseurl Posix.</> p

genCredentials :: CredPair -> IO AWS.Credentials
genCredentials (keyid, secret) = AWS.Credentials
	<$> pure (tobs keyid)
	<*> pure (tobs secret)
	<*> newIORef []
	<*> (fmap tobs <$> getEnv "AWS_SESSION_TOKEN")
  where
	tobs = T.encodeUtf8 . T.pack

mkLocationConstraint :: AWS.Region -> S3.LocationConstraint
mkLocationConstraint "US" = S3.locationUsClassic
mkLocationConstraint r = r

debugMapper :: AWS.Logger
debugMapper level t = forward "S3" (T.unpack t)
  where
	forward = case level of
		AWS.Debug -> debugM
		AWS.Info -> infoM
		AWS.Warning -> warningM
		AWS.Error -> errorM

s3Info :: RemoteConfig -> S3Info -> [(String, String)]
s3Info c info = catMaybes
	[ Just ("bucket", fromMaybe "unknown" (getBucketName c))
	, Just ("endpoint", w82s (BS.unpack (S3.s3Endpoint s3c)))
	, Just ("port", show (S3.s3Port s3c))
	, Just ("storage class", showstorageclass (getStorageClass c))
	, if configIA c
		then Just ("internet archive item", iaItemUrl $ fromMaybe "unknown" $ getBucketName c)
		else Nothing
	, Just ("partsize", maybe "unlimited" (roughSize storageUnits False) (getPartSize c))
	, Just ("public", if public info then "yes" else "no")
	, Just ("versioning", if versioning info then "yes" else "no")
	]
  where
	s3c = s3Configuration c
#if MIN_VERSION_aws(0,13,0)
	showstorageclass (S3.OtherStorageClass t) = T.unpack t
#endif
	showstorageclass sc = show sc

getPublicWebUrls :: UUID -> S3Info -> RemoteConfig -> Key -> Annex [URLString]
getPublicWebUrls u info c k
	| not (public info) = return []
	| exportTree c = if versioning info
		then case publicurl info of
			Just url -> getS3VersionIDPublicUrls (const $ genericPublicUrl url) info u k
			Nothing -> case host info of
				Just h | h == AWS.s3DefaultHost ->
					getS3VersionIDPublicUrls awsPublicUrl info u k
				_ -> return []
		else return []
	| otherwise = case getPublicUrlMaker info of
		Just geturl -> return [geturl $ bucketObject info k]
		Nothing -> return []

getPublicUrlMaker :: S3Info -> Maybe (BucketObject -> URLString)
getPublicUrlMaker info = case publicurl info of
	Just url -> Just (genericPublicUrl url)
	Nothing -> case host info of
		Just h
			| h == AWS.s3DefaultHost ->
				Just (awsPublicUrl info)
			| isIAHost h ->
				Just (iaPublicUrl info)
		_ -> Nothing


data S3VersionID = S3VersionID S3.Object String
	deriving (Show)

-- smart constructor
mkS3VersionID :: S3.Object -> Maybe T.Text -> Maybe S3VersionID
mkS3VersionID o = mkS3VersionID' o . fmap T.unpack

mkS3VersionID' :: S3.Object -> Maybe String -> Maybe S3VersionID
mkS3VersionID' o (Just s)
	| null s = Nothing
	-- AWS documentation says a version ID is at most 1024 bytes long.
	-- Since they are stored in the git-annex branch, prevent them from
	-- being very much larger than that.
	| length s < 2048 = Just (S3VersionID o s)
	| otherwise = Nothing
mkS3VersionID' _ Nothing = Nothing

-- Format for storage in per-remote metadata.
--
-- A S3 version ID is "url ready" so does not contain '#' and so we'll use
-- that to separate it from the object id. (Could use a space, but spaces
-- in metadata values lead to an inefficient encoding.)
formatS3VersionID :: S3VersionID -> String
formatS3VersionID (S3VersionID o v) = v ++ '#' : T.unpack o

-- Parse from value stored in per-remote metadata.
parseS3VersionID :: String -> Maybe S3VersionID
parseS3VersionID s = 
	let (v, o) = separate (== '#') s
	in mkS3VersionID' (T.pack o) (Just v)

setS3VersionID :: S3Info -> UUID -> Key -> Maybe S3VersionID -> Annex ()
setS3VersionID info u k vid
	| versioning info = maybe noop (setS3VersionID' u k) vid
	| otherwise = noop

setS3VersionID' :: UUID -> Key -> S3VersionID -> Annex ()
setS3VersionID' u k vid = addRemoteMetaData k $
	RemoteMetaData u (updateMetaData s3VersionField v emptyMetaData)
  where
	v = mkMetaValue (CurrentlySet True) (formatS3VersionID vid)

getS3VersionID :: UUID -> Key -> Annex [S3VersionID]
getS3VersionID u k = do
	(RemoteMetaData _ m) <- getCurrentRemoteMetaData u k
	return $ mapMaybe parseS3VersionID $ map unwrap $ S.toList $
		metaDataValues s3VersionField m
  where
	unwrap (MetaValue _ v) = v

s3VersionField :: MetaField
s3VersionField = mkMetaFieldUnchecked "V"

eitherS3VersionID :: S3Info -> UUID -> Key -> S3.Object -> Annex (Either S3.Object S3VersionID)
eitherS3VersionID info u k fallback
	| versioning info = getS3VersionID u k >>= return . \case
		[] -> Left fallback
		-- It's possible for a key to be stored multiple timees in
		-- a bucket with different version IDs; only use one of them.
		(v:_) -> Right v
	| otherwise = return (Left fallback)

s3VersionIDPublicUrl :: (S3Info -> BucketObject -> URLString) -> S3Info -> S3VersionID -> URLString
s3VersionIDPublicUrl mk info (S3VersionID obj vid) = mk info $ concat
	[ T.unpack obj
	, "?versionId="
	, vid -- version ID is "url ready" so no escaping needed
	]

getS3VersionIDPublicUrls :: (S3Info -> BucketObject -> URLString) -> S3Info -> UUID -> Key -> Annex [URLString]
getS3VersionIDPublicUrls mk info u k =
	map (s3VersionIDPublicUrl mk info) <$> getS3VersionID u k
