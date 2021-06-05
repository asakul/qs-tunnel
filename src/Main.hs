{-# LANGUAGE OverloadedStrings #-}

module Main where

import           Data.Aeson
import qualified Data.ByteString           as B
import qualified Data.ByteString.Char8     as B8
import qualified Data.ByteString.Lazy      as BL
import qualified Data.List                 as L
import           Data.List.NonEmpty
import qualified Data.Text                 as T
import           Data.Time.Clock

import           Control.Applicative
import           Control.Monad

import           System.IO
import           System.Log.Formatter
import           System.Log.Handler        (setFormatter)
import           System.Log.Handler.Simple
import           System.Log.Logger
import           System.ZMQ4               hiding (events)
import           System.ZMQ4.ZAP

import           Options.Applicative

data CommandLineConfig = CommandLineConfig
  {
    clConfigPath :: Maybe FilePath
  } deriving (Show, Eq)

data UpstreamConfig = UpstreamConfig
  {
    ucEndpoint        :: T.Text,
    ucCertificatePath :: Maybe FilePath
  } deriving (Show, Eq)

instance FromJSON UpstreamConfig where
  parseJSON (Object o) =
    UpstreamConfig      <$>
    o .:  "endpoint"    <*>
    o .:? "certificate"
  parseJSON _ = fail "Expected object"

data Config = Config
  {
    confDownstreamEp                  :: T.Text,
    confDownstreamCertificatePath     :: Maybe FilePath,
    confClientCertificates            :: [FilePath],
    confWhitelistIps                  :: [T.Text],
    confBlacklistIps                  :: [T.Text],
    confUpstreams                     :: [UpstreamConfig],
    confUpstreamClientCertificatePath :: Maybe FilePath,
    confTimeout                       :: Integer
  } deriving (Show, Eq)

instance FromJSON Config where
  parseJSON (Object o) =
    Config                                <$>
    o .:  "downstream"                    <*>
    o .:? "downstream_certificate"        <*>
    o .:? "client_certificates" .!= []    <*>
    o .:? "whitelist"   .!= []            <*>
    o .:? "blacklist"   .!= []            <*>
    o .:  "upstreams"                     <*>
    o .:? "upstream_client_certificate"   <*>
    o .:  "timeout"

  parseJSON _ = fail "Expected object"

initLogging :: IO ()
initLogging = do
  handler <- streamHandler stderr DEBUG >>=
    (\x -> return $
      setFormatter x (simpleLogFormatter "$utcTime\t {$loggername} <$prio> -> $msg"))

  hSetBuffering stderr LineBuffering
  updateGlobalLogger rootLoggerName (setLevel DEBUG)
  updateGlobalLogger rootLoggerName (setHandlers [handler])

parseCommandLineConfig :: Parser CommandLineConfig
parseCommandLineConfig = CommandLineConfig
  <$> (optional $ strOption (long "config" <> short 'c' <> help "Config to use"))

main :: IO ()
main = do
  cfg <- execParser opts
  initLogging
  infoM "main" "Starting"
  eConf <- eitherDecode . BL.fromStrict <$> B.readFile (configPath cfg)
  case eConf of
    Left errMsg -> error errMsg
    Right conf  -> runWithConfig conf
  where
    configPath cfg = case clConfigPath cfg of
      Just path -> path
      Nothing   -> "qs-tunnel.conf"
    opts = info (parseCommandLineConfig <**> helper)
       ( fullDesc
      <> progDesc "Quotesource tunnel" )

runWithConfig :: Config -> IO ()
runWithConfig conf = do
  withContext $ \ctx ->
    withZapHandler ctx $ \zap -> do
      withSocket ctx Pub $ \downstream -> do
        setZapDomain (restrict "global") downstream
        zapSetBlacklist zap "global" $ confBlacklistIps conf
        zapSetWhitelist zap "global" $ confWhitelistIps conf
        case (confDownstreamCertificatePath conf) of
          Just certPath -> do
            eCert <- loadCertificateFromFile certPath
            case eCert of
              Left err -> errorM "main" $ "Unable to load certificate: " ++ certPath ++ "; " ++ err
              Right cert -> do
                setCurveServer True downstream
                zapApplyCertificate cert downstream
                forM_ (confClientCertificates conf) (addCertificate zap)
          _ -> return ()
        bind downstream $ T.unpack $ confDownstreamEp conf

        upstreamCert <- case confUpstreamClientCertificatePath conf of
          Just fp -> do
            ec <- loadCertificateFromFile fp
            case ec of
              Left err -> do
                errorM "main" $ "Unable to load certificate: " ++ fp ++ "; " ++ err
                return Nothing
              Right cert -> return $ Just cert
          _ -> return Nothing
        now <- getCurrentTime
        infoM "main" "Creating sockets"
        sockets <- forM (confUpstreams conf) $ \upstreamConf -> do
          infoM "main" $ "Creating: " ++ (T.unpack $ ucEndpoint upstreamConf)
          s <- socket ctx Sub
          maybeSc <- case (ucCertificatePath upstreamConf) of
            Just certPath -> do
              eCert <- loadCertificateFromFile certPath
              case eCert of
                Left err -> do
                  errorM "main" $ "Unable to load certificate: " ++ certPath ++ "; " ++ err
                  return Nothing
                Right cert -> return $ Just cert
            _ -> return Nothing
          maybeCc <- case upstreamCert of
            Just cert -> return $ Just cert
            Nothing   -> return Nothing

          infoM "main" $ "Connecting: " ++ (T.unpack $ ucEndpoint upstreamConf)
          case (maybeSc, maybeCc) of
            (Just serverCert, Just clientCert) -> do
              zapSetServerCertificate serverCert s
              zapApplyCertificate clientCert s
            _ -> return ()

          connect s $ T.unpack $ ucEndpoint upstreamConf
          subscribe s B.empty
          return (s, ucEndpoint upstreamConf, maybeSc, maybeCc, now)

        infoM "main" "Starting main loop"
        go ctx downstream sockets now
  where
    go ctx downstream sockets lastHeartbeat = do
      events <- poll 200 $ fmap (\(s, _, _, _, _) -> Sock s [In] Nothing) sockets
      let z = L.zip sockets events
      now <- getCurrentTime
      sockets' <- forM z $ \((s, ep, maybeSc, maybeCc, lastActivity), evts) -> do
        if (not . null $ evts)
          then do
            incoming <- receiveMulti s
            case incoming of
              x:xs -> sendMulti downstream $ x :| xs
              _    -> return ()
            return (s, ep, maybeSc, maybeCc, now)
          else do
            if now `diffUTCTime` lastActivity < (fromInteger . confTimeout) conf
              then return (s, ep, maybeSc, maybeCc, lastActivity)
              else do
                close s
                debugM "main" $ "Reconnecting: " ++ T.unpack ep
                newS <- socket ctx Sub
                case (maybeSc, maybeCc) of
                  (Just serverCert, Just clientCert) -> do
                    zapSetServerCertificate serverCert newS
                    zapApplyCertificate clientCert newS
                  _ -> return ()
                connect newS $ T.unpack ep
                subscribe newS B.empty
                return (newS, ep, maybeSc, maybeCc, now)

      if (now `diffUTCTime` lastHeartbeat < 1)
        then go ctx downstream sockets' lastHeartbeat
        else do
          send downstream [] $ B8.pack "SYSTEM#HEARTBEAT"
          go ctx downstream sockets' now

    addCertificate zap clientCertPath = do
      eClientCert <- loadCertificateFromFile clientCertPath
      case eClientCert of
        Left err -> errorM "main" $ "Unable to load client certificate: " ++ clientCertPath ++ "; " ++ err
        Right clientCert -> zapAddClientCertificate zap "global" clientCert


