{- git-annex worktree files
 -
 - Copyright 2013-2018 Joey Hess <id@joeyh.name>
 -
 - Licensed under the GNU GPL version 3 or higher.
 -}

module Annex.WorkTree where

import Annex.Common
import Annex.Link
import Annex.CatFile
import Annex.Version
import Annex.Content
import Annex.ReplaceFile
import Annex.CurrentBranch
import Config
import Git.FilePath
import qualified Git.Ref
import qualified Git.Branch
import qualified Git.LsTree
import qualified Git.Types
import Database.Types
import qualified Database.Keys
import qualified Database.Keys.SQL

{- Looks up the key corresponding to an annexed file in the work tree,
 - by examining what the file links to.
 -
 - An unlocked file will not have a link on disk, so fall back to
 - looking for a pointer to a key in git.
 -
 - When in an adjusted branch that may have hidden the file, looks for a
 - pointer to a key in the original branch.
 -}
lookupFile :: FilePath -> Annex (Maybe Key)
lookupFile file = isAnnexLink file >>= \case
	Just key -> return (Just key)
	Nothing -> ifM (versionSupportsUnlockedPointers <||> isDirect)
		( ifM (liftIO $ doesFileExist file)
			( catKeyFile file
			, catKeyFileHidden file =<< getCurrentBranch
			)
		, return Nothing 
		)

{- Modifies an action to only act on files that are already annexed,
 - and passes the key on to it. -}
whenAnnexed :: (FilePath -> Key -> Annex (Maybe a)) -> FilePath -> Annex (Maybe a)
whenAnnexed a file = ifAnnexed file (a file) (return Nothing)

ifAnnexed :: FilePath -> (Key -> Annex a) -> Annex a -> Annex a
ifAnnexed file yes no = maybe no yes =<< lookupFile file

{- Find all unlocked files and update the keys database for them. 
 - 
 - This is expensive, and so normally the associated files are updated
 - incrementally when changes are noticed. So, this only needs to be done
 - when initializing/upgrading a v6 mode repository.
 -
 - Also, the content for the unlocked file may already be present as
 - an annex object. If so, make the unlocked file use that content.
 -}
scanUnlockedFiles :: Annex ()
scanUnlockedFiles = whenM (isJust <$> inRepo Git.Branch.current) $ do
	showSideAction "scanning for unlocked files"
	Database.Keys.runWriter $
		liftIO . Database.Keys.SQL.dropAllAssociatedFiles
	(l, cleanup) <- inRepo $ Git.LsTree.lsTree Git.Ref.headRef
	forM_ l $ \i -> 
		when (isregfile i) $
			maybe noop (add i)
				=<< catKey (Git.LsTree.sha i)
	liftIO $ void cleanup
  where
	isregfile i = case Git.Types.toTreeItemType (Git.LsTree.mode i) of
		Just Git.Types.TreeFile -> True
		Just Git.Types.TreeExecutable -> True
		_ -> False
	add i k = do
		let tf = Git.LsTree.file i
		Database.Keys.runWriter $
			liftIO . Database.Keys.SQL.addAssociatedFileFast (toIKey k) tf
		whenM (inAnnex k) $ do
			f <- fromRepo $ fromTopFilePath tf
			destmode <- liftIO $ catchMaybeIO $ fileMode <$> getFileStatus f
			replaceFile f $ \tmp ->
				linkFromAnnex k tmp destmode >>= \case
					LinkAnnexOk -> return ()
					LinkAnnexNoop -> return ()
					LinkAnnexFailed -> liftIO $
						writePointerFile tmp k destmode
