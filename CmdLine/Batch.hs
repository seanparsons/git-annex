{- git-annex batch commands
 -
 - Copyright 2015 Joey Hess <id@joeyh.name>
 -
 - Licensed under the GNU GPL version 3 or higher.
 -}

module CmdLine.Batch where

import Annex.Common
import Types.Command
import CmdLine.Action
import CmdLine.GitAnnex.Options
import Options.Applicative
import Limit
import Types.FileMatcher

data BatchMode = Batch BatchFormat | NoBatch

data BatchFormat = BatchLine | BatchNull

parseBatchOption :: Parser BatchMode
parseBatchOption = go 
	<$> switch
		( long "batch"
		<> help "enable batch mode"
		)
	<*> switch
		( short 'z'
		<> help "null delimited batch input"
		)
  where
	go True False = Batch BatchLine
 	go True True = Batch BatchNull
	go False _ = NoBatch

-- A batchable command can run in batch mode, or not.
-- In batch mode, one line at a time is read, parsed, and a reply output to
-- stdout. In non batch mode, the command's parameters are parsed and
-- a reply output for each.
batchable :: (opts -> String -> Annex Bool) -> Parser opts -> CmdParamsDesc -> CommandParser
batchable handler parser paramdesc = batchseeker <$> batchparser
  where
	batchparser = (,,)
		<$> parser
		<*> parseBatchOption
		<*> cmdParams paramdesc
	
	batchseeker (opts, NoBatch, params) =
		mapM_ (go NoBatch opts) params
	batchseeker (opts, batchmode@(Batch fmt), _) = 
		batchInput fmt Right (go batchmode opts)

	go batchmode opts p =
		unlessM (handler opts p) $
			batchBadInput batchmode

-- bad input is indicated by an empty line in batch mode. In non batch
-- mode, exit on bad input.
batchBadInput :: BatchMode -> Annex ()
batchBadInput NoBatch = liftIO exitFailure
batchBadInput (Batch _) = liftIO $ putStrLn ""

-- Reads lines of batch mode input and passes to the action to handle.
batchInput :: BatchFormat -> (String -> Either String a) -> (a -> Annex ()) -> Annex ()
batchInput fmt parser a = go =<< batchLines fmt
  where
	go [] = return ()
	go (l:rest) = do
		either parseerr a (parser l)
		go rest
	parseerr s = giveup $ "Batch input parse failure: " ++ s

batchLines :: BatchFormat -> Annex [String]
batchLines fmt = liftIO $ splitter <$> getContents
  where
	splitter = case fmt of
		BatchLine -> lines
		BatchNull -> splitc '\0'

-- Runs a CommandStart in batch mode.
--
-- The batch mode user expects to read a line of output, and it's up to the
-- CommandStart to generate that output as it succeeds or fails to do its
-- job. However, if it stops without doing anything, it won't generate
-- any output, so in that case, batchBadInput is used to provide the caller
-- with an empty line.
batchCommandAction :: CommandStart -> Annex ()
batchCommandAction a = maybe (batchBadInput (Batch BatchLine)) (const noop)
	=<< callCommandAction' a

-- Reads lines of batch input and passes the filepaths to a CommandStart
-- to handle them.
--
-- File matching options are not checked.
allBatchFiles :: BatchFormat -> (FilePath -> CommandStart) -> Annex ()
allBatchFiles fmt a = batchInput fmt Right $ batchCommandAction . a

-- Like allBatchFiles, but checks the file matching options
-- and skips non-matching files.
batchFilesMatching :: BatchFormat -> (FilePath -> CommandStart) -> Annex ()
batchFilesMatching fmt a = do
	matcher <- getMatcher
	allBatchFiles fmt $ \f ->
		ifM (matcher $ MatchingFile $ FileInfo f f)
			( a f
			, return Nothing
			)
