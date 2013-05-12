{- temp file functions
 -
 - Copyright 2010-2013 Joey Hess <joey@kitenet.net>
 -
 - Licensed under the GNU GPL version 3 or higher.
 -}

module Utility.TempFile where

import Control.Exception (bracket)
import System.IO
import System.Directory
import Control.Monad.IfElse

import Utility.Exception
import System.FilePath

type Template = String

{- Runs an action like writeFile, writing to a temp file first and
 - then moving it into place. The temp file is stored in the same
 - directory as the final file to avoid cross-device renames. -}
viaTmp :: (FilePath -> String -> IO ()) -> FilePath -> String -> IO ()
viaTmp a file content = do
	let (dir, base) = splitFileName file
	createDirectoryIfMissing True dir
	(tmpfile, handle) <- openTempFile dir (base ++ ".tmp")
	hClose handle
	a tmpfile content
	renameFile tmpfile file

{- Runs an action with a tmp file located in the system's tmp directory
 - (or in "." if there is none) then removes the file. -}
withTempFile :: Template -> (FilePath -> Handle -> IO a) -> IO a
withTempFile template a = do
	tmpdir <- catchDefaultIO "." getTemporaryDirectory
	withTempFileIn tmpdir template a

{- Runs an action with a tmp file located in the specified directory,
 - then removes the file. -}
withTempFileIn :: FilePath -> Template -> (FilePath -> Handle -> IO a) -> IO a
withTempFileIn tmpdir template a = bracket create remove use
  where
	create = openTempFile tmpdir template
	remove (name, handle) = do
		hClose handle
		catchBoolIO (removeFile name >> return True)
	use (name, handle) = a name handle

{- Runs an action with a tmp directory located within the system's tmp
 - directory (or within "." if there is none), then removes the tmp
 - directory and all its contents. -}
withTempDir :: Template -> (FilePath -> IO a) -> IO a
withTempDir template a = do
	tmpdir <- catchDefaultIO "." getTemporaryDirectory
	withTempDirIn tmpdir template a

{- Runs an action with a tmp directory located within a specified directory,
 - then removes the tmp directory and all its contents. -}
withTempDirIn :: FilePath -> Template -> (FilePath -> IO a) -> IO a
withTempDirIn tmpdir template = bracket create remove
  where
	remove d = whenM (doesDirectoryExist d) $
		removeDirectoryRecursive d
	create = do
		createDirectoryIfMissing True tmpdir
		makenewdir (tmpdir </> template) (0 :: Int)
	makenewdir t n = do
		let dir = t ++ "." ++ show n
		either (const $ makenewdir t $ n + 1) (const $ return dir)
			=<< tryIO (createDirectory dir)
