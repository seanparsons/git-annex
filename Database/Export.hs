{- Sqlite database used for exports to special remotes.
 -
 - Copyright 2017 Joey Hess <id@joeyh.name>
 -:
 - Licensed under the GNU GPL version 3 or higher.
 -}

{-# LANGUAGE QuasiQuotes, TypeFamilies, TemplateHaskell #-}
{-# LANGUAGE OverloadedStrings, GADTs, FlexibleContexts #-}
{-# LANGUAGE MultiParamTypeClasses, GeneralizedNewtypeDeriving #-}
{-# LANGUAGE RankNTypes #-}

module Database.Export (
	ExportHandle,
	openDb,
	closeDb,
	flushDbQueue,
	recordDataSource,
	getDataSource,
	addExportedLocation,
	removeExportedLocation,
	getExportedLocation,
	isExportDirectoryEmpty,
	getExportTree,
	updateExportTree,
	ExportedId,
	ExportTreeId,
	ExportedDirectoryId,
	DataSourceId,
) where

import Database.Types
import qualified Database.Queue as H
import Database.Init
import Annex.Locations
import Annex.Common hiding (delete)
import Types.Export
import Annex.Export
import Git.Types
import Git.Sha
import Git.FilePath
import qualified Git.DiffTree

import Database.Persist.TH
import Database.Esqueleto hiding (Key)

newtype ExportHandle = ExportHandle H.DbQueue

share [mkPersist sqlSettings, mkMigrate "migrateExport"] [persistLowerCase|
-- Files that have been exported to the remote.
Exported
  key IKey
  file SFilePath
  ExportedIndex key file
-- The tree that has been exported to the remote. 
-- Not all of these files are necessarily present on the remote yet.
ExportTree
  key IKey
  file SFilePath
  ExportTreeIndex key file
-- Directories that exist on the remote, and the files that are in them.
ExportedDirectory
  subdir SFilePath
  file SFilePath
  ExportedDirectoryIndex subdir file
-- Record of what tree the current database content comes from.
DataSource
  tree SRef
  UniqueTree tree
|]

{- Opens the database, creating it if it doesn't exist yet. -}
openDb :: UUID -> Annex ExportHandle
openDb u = do
	dbdir <- fromRepo (gitAnnexExportDbDir u)
	let db = dbdir </> "db"
	unlessM (liftIO $ doesFileExist db) $ do
		initDb db $ void $
			runMigrationSilent migrateExport
	h <- liftIO $ H.openDbQueue H.SingleWriter db "exported"
	return $ ExportHandle h

closeDb :: ExportHandle -> Annex ()
closeDb (ExportHandle h) = liftIO $ H.closeDbQueue h

queueDb :: ExportHandle -> SqlPersistM () -> IO ()
queueDb (ExportHandle h) = H.queueDb h checkcommit
  where
	-- commit queue after 1000 changes
	checkcommit sz _lastcommittime
		| sz > 1000 = return True
		| otherwise = return False

flushDbQueue :: ExportHandle -> IO ()
flushDbQueue (ExportHandle h) = H.flushDbQueue h

recordDataSource :: ExportHandle -> Sha -> IO ()
recordDataSource h s = queueDb h $ do
	delete $ from $ \r -> do
		where_ (r ^. DataSourceTree ==. r ^. DataSourceTree)
	void $ insertUnique $ DataSource (toSRef s)

getDataSource :: ExportHandle -> IO (Maybe Sha)
getDataSource (ExportHandle h) = H.queryDbQueue h $ do
	l <- select $ from $ \r -> do
		where_ (r ^. DataSourceTree ==. r ^. DataSourceTree)
		return (r ^. DataSourceTree)
	case l of
		(s:[]) -> return (Just (fromSRef (unValue s)))
		_ -> return Nothing

addExportedLocation :: ExportHandle -> Key -> ExportLocation -> IO ()
addExportedLocation h k el = queueDb h $ do
	void $ insertUnique $ Exported ik ef
	insertMany_ $ map
		(\ed -> ExportedDirectory (toSFilePath (fromExportDirectory ed)) ef)
		(exportDirectories el)
  where
	ik = toIKey k
	ef = toSFilePath (fromExportLocation el)

removeExportedLocation :: ExportHandle -> Key -> ExportLocation -> IO ()
removeExportedLocation h k el = queueDb h $ do
	delete $ from $ \r -> do
		where_ (r ^. ExportedKey ==. val ik &&. r ^. ExportedFile ==. val ef)
	let subdirs = map (toSFilePath . fromExportDirectory)
		(exportDirectories el)
	delete $ from $ \r -> do
		where_ (r ^. ExportedDirectoryFile ==. val ef
			&&. r ^. ExportedDirectorySubdir `in_` valList subdirs)
  where
	ik = toIKey k
	ef = toSFilePath (fromExportLocation el)

{- Note that this does not see recently queued changes. -}
getExportedLocation :: ExportHandle -> Key -> IO [ExportLocation]
getExportedLocation (ExportHandle h) k = H.queryDbQueue h $ do
	l <- select $ from $ \r -> do
		where_ (r ^. ExportedKey ==. val ik)
		return (r ^. ExportedFile)
	return $ map (mkExportLocation . fromSFilePath . unValue) l
  where
	ik = toIKey k

{- Note that this does not see recently queued changes. -}
isExportDirectoryEmpty :: ExportHandle -> ExportDirectory -> IO Bool
isExportDirectoryEmpty (ExportHandle h) d = H.queryDbQueue h $ do
	l <- select $ from $ \r -> do
		where_ (r ^. ExportedDirectorySubdir ==. val ed)
		return (r ^. ExportedDirectoryFile)
	return $ null l
  where
	ed = toSFilePath $ fromExportDirectory d

{- Get locations in the export that might contain a key. -}
getExportTree :: ExportHandle -> Key -> IO [ExportLocation]
getExportTree (ExportHandle h) k = H.queryDbQueue h $ do
	l <- select $ from $ \r -> do
		where_ (r ^. ExportTreeKey ==. val ik)
		return (r ^. ExportTreeFile)
	return $ map (mkExportLocation . fromSFilePath . unValue) l
  where
	ik = toIKey k

addExportTree :: ExportHandle -> Key -> ExportLocation -> IO ()
addExportTree h k loc = queueDb h $
	void $ insertUnique $ Exported ik ef
  where
	ik = toIKey k
	ef = toSFilePath (fromExportLocation loc)

removeExportTree :: ExportHandle -> Key -> ExportLocation -> IO ()
removeExportTree h k loc = queueDb h $ 
	delete $ from $ \r ->
		where_ (r ^. ExportTreeKey ==. val ik &&. r ^. ExportTreeFile ==. val ef)
  where
	ik = toIKey k
	ef = toSFilePath (fromExportLocation loc)

{- Diff from the old to the new tree and update the ExportTree table. -}
updateExportTree :: ExportHandle -> Sha -> Sha -> Annex ()
updateExportTree h old new = do
	(diff, cleanup) <- inRepo $
		Git.DiffTree.diffTreeRecursive old new
	forM_ diff $ \i -> do
		let loc = mkExportLocation $ getTopFilePath $
			Git.DiffTree.file i
		srcek <- getek (Git.DiffTree.srcsha i)
		case srcek of
			Nothing -> return ()
			Just k -> liftIO $ removeExportTree h (asKey k) loc
		dstek <- getek (Git.DiffTree.dstsha i)
		case dstek of
			Nothing -> return ()
			Just k -> liftIO $ addExportTree h (asKey k) loc
	void $ liftIO cleanup
  where
	getek sha
		| sha == nullSha = return Nothing
		| otherwise = Just <$> exportKey sha
