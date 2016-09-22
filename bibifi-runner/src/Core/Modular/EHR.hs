module Core.Modular.EHR where

import Control.Monad.Error
import qualified Data.IORef.Lifted as IO
import qualified Data.List as List
import Data.Monoid
-- import qualified Data.Text as Text
import qualified Data.Text.Encoding as Text
import qualified Data.Text.Encoding.Error as Text
import Network.SSH.Client.SimpleSSH
import Yesod.Form.Fields (Textarea(..))

import Cloud
import Common
-- import Core.DatabaseM
import Core.Modular.Class
import Core.Modular.Shared
import Core.Score
import Core.SSH

newtype EHRSpec = EHRSpec (Entity Contest)

instance ModularContest EHRSpec where
    scoreContestBuild (EHRSpec (Entity cId _)) _ = defaultScoreBuildRound cId
    scoreContestBreak (EHRSpec (Entity cId _)) _ = defaultScoreBreakRound cId
    scoreContestFix (EHRSpec (Entity cId _)) _ = defaultScoreFixRound cId

    runOracleSubmission (EHRSpec _contest) _opts (Entity _submissionId _submission) = do
        undefined

    runBuildSubmission (EHRSpec (Entity contestId _contest)) opts (Entity submissionId submission) = do
        -- Retrieve tests from database.
        coreTests' <- runDB $ selectList [ContestCoreTestContest ==. contestId] []
        performanceTests' <- runDB $ selectList [ContestPerformanceTestContest ==. contestId] []
        optionalTests' <- runDB $ selectList [ContestOptionalTestContest ==. contestId] []

        coreDoneRef <- IO.newIORef False
        resultsE <- runErrorT $ do
            -- Parse tests.
            coreTests <- mapM parseCoreTest coreTests'
            performanceTests <- mapM parsePerformanceTest performanceTests'
            optionalTests <- mapM parseOptionalTest optionalTests'

            -- Make sure build submission tar and MITMs exist.
            archiveLocation <- getBuildArchiveLocation submission opts 

            -- Delete any previous stored results.
            lift $ runDB $ deleteWhere [BuildCoreResultSubmission ==. submissionId]
            lift $ runDB $ deleteWhere [BuildPerformanceResultSubmission ==. submissionId]
            lift $ runDB $ deleteWhere [BuildOptionalResultSubmission ==. submissionId]

            let conf = runnerCloudConfiguration opts
            let manager = runnerHttpManager opts
            launchOneInstanceWithTimeout conf manager 60 $ \_inst session -> do
                putLog "Sending build submission."
                let destArchiveLocation = "/home/ubuntu/submission.tar.gz"
                _ <- runSSH (BuildError "Could not send submission") $ sendFile session 0o666 archiveLocation destArchiveLocation

                -- setupFirewall session

                -- Setup directory.
                (Result _ _ exit) <- runSSH (BuildError "Could not make test directory.") $ execCommand session "sudo -i -u builder mkdir /home/builder/submission"
                when (exit /= ExitSuccess) $
                    fail "Could not make test directory."

                -- Extract submission.
                putLog "Extracting build submission."
                (Result _ _ exit) <- runSSH (BuildError "Could not extract submission") $ execCommand session ("cd /home/builder/submission; sudo -u builder tar -xf " <> destArchiveLocation)
                when (exit /= ExitSuccess) $ 
                    fail "Could not extract submission"

                -- Build submission. 
                putLog "Building submission."
                (Result stderr stdout exit) <- runSSH (BuildError "Could not run make") $ execCommand session "sudo -i -u builder make -B -C /home/builder/submission/build"
                when (exit /= ExitSuccess) $
                    throwError $ BuildFail stderr stdout

                -- Map over tests.
                let (requiredTests, optTests) = List.partition (isBuildTestRequired . fst) (coreTests <> performanceTests <> optionalTests)
                requiredResults <- mapM (runBuildTest session) requiredTests
                -- TODO: deepseq or custom mapM? Flush results?
                mapM_ (recordBuildResult submissionId) requiredResults

                -- Indicate core tests passed. 
                coreDoneRef `IO.writeIORef` True

                -- Continue running optional tests.
                mapM_ (\test -> do
                    result <- runBuildTest session test
                    (recordBuildResult submissionId) result
                  ) optTests

        case (resultsE :: Either BuildError ()) of
            Left (BuildFail stdout' stderr') -> do
                let stdout = Just $ Textarea $ Text.decodeUtf8With Text.lenientDecode stdout'
                let stderr = Just $ Textarea $ Text.decodeUtf8With Text.lenientDecode stderr'
                runDB $ update submissionId [BuildSubmissionStatus =. BuildBuildFail, BuildSubmissionStdout =. stdout, BuildSubmissionStderr =. stderr]
                putLog "Build failed"
                return $ Just (True, False)
            Left (BuildError err) -> do
                putLog err
                return $ Just (False, False)
            Left BuildErrorTimeout -> do
                -- Timeout.
                -- Check if core completed.
                coreDone <- IO.readIORef coreDoneRef
                if coreDone then 
                    buildBuilt
                else
                    return Nothing
            Right () ->
                buildBuilt
        
        where
            buildBuilt = do
                runDB $ update submissionId [BuildSubmissionStatus =. BuildBuilt]
                return $ Just (True, True)


    runBreakSubmission (EHRSpec (Entity _contestId _contest)) _opts _bsE@(Entity _submissionId _submission) = do
        undefined

    runFixSubmission (EHRSpec (Entity _contestId _contest)) _opts (Entity _submissionId _submission) = do
        undefined
