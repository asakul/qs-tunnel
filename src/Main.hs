{-# LANGUAGE OverloadedStrings #-}

module Main where

import           Data.Aeson
import qualified Data.ByteString           as B
import qualified Data.ByteString.Char8     as B8
import qualified Data.ByteString.Lazy      as BL
import           Data.IORef
import qualified Data.List                 as L
import           Data.List.NonEmpty
import qualified Data.Text                 as T
import           Data.Time.Clock

import           ATrade.QuoteSource.Client
import           ATrade.QuoteSource.Server

import           Control.Applicative
import           Control.Concurrent
import           Control.Monad
import           Control.Monad.Loops

import           System.IO
import           System.Log.Formatter
import           System.Log.Handler        (setFormatter)
import           System.Log.Handler.Simple
import           System.Log.Logger
import           System.ZMQ4
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

data Config = Config
  {
    confDownstreamEp              :: T.Text,
    confDownstreamCertificatePath :: Maybe FilePath,
    confClientCertificates        :: [FilePath],
    confWhitelistIps              :: [T.Text],
    confBlacklistIps              :: [T.Text],
    confUpstreams                 :: [UpstreamConfig],
    confTimeout                   :: Integer
  } deriving (Show, Eq)

instance FromJSON Config where
  parseJSON (Object o) =
    Config                         <$>
    o .:  "downstream"             <*>
    o .:? "downstream_certificate" <*>
    o .:  "client_certificates"    <*>
    o .:? "whitelist"   .!= []     <*>
    o .:? "blacklist"   .!= []     <*>
    o .:  "upstreams"              <*>
    o .:  "timeout"

  parseJSON _ = fail "Expected object"

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

runWithConfig conf = do
  withContext $ \ctx ->
    withZapHandler ctx $ \zap -> do
      withSocket ctx Pub $ \downstream -> do
        setZapDomain (restrict "global") downstream
        zapSetBlacklist zap "global" $ confBlacklistIps conf
        zapSetWhitelist zap "global" $ confWhitelistIps conf
        bind downstream $ T.unpack $ confDownstreamEp conf
        case (confDownstreamCertificatePath conf) of
          Just certPath -> do
            eCert <- loadCertificateFromFile certPath
            case eCert of
              Left err -> errorM "main" $ "Unable to load certificate: " ++ certPath
              Right cert -> do
                zapSetServerCertificate cert downstream
                forM_ (confClientCertificates conf) (addCertificate zap)
          _ -> return ()

        forM_ (confUpstreams conf) $ \upstreamConf -> forkIO $ do
          forever $ withSocket ctx Sub $ \upstream -> do
            infoM "main" $ "Connecting to: " ++ (T.unpack $ ucEndpoint upstreamConf)
            case (ucCertificatePath upstreamConf) of
              Just certPath -> do
                eCert <- loadCertificateFromFile certPath
                case eCert of
                  Left err -> errorM "main" $ "Unable to load certificate: " ++ certPath
                  Right cert -> zapApplyCertificate cert upstream
              _ -> return ()
            connect upstream $ T.unpack $ ucEndpoint upstreamConf
            subscribe upstream B.empty
            now <- getCurrentTime
            lastHeartbeat <- newIORef now
            lastHeartbeatSent <- newIORef now
            infoM "main" "Starting proxy loop"
            whileM (notTimeout lastHeartbeat conf) $ do
              evs <- poll 200 [Sock upstream [In] Nothing]
              sendHeartbeatIfNeeded lastHeartbeatSent downstream
              unless (null (L.head evs)) $ do
                incoming <- receiveMulti upstream
                case incoming of
                  x:xs -> do
                    now <- getCurrentTime
                    writeIORef lastHeartbeat now
                    sendMulti downstream $ x :| xs
                  _ -> return ()
        forever $ threadDelay 100000
  where
    notTimeout ref conf = do
      now <- getCurrentTime
      lastHb <- readIORef ref
      return $ now `diffUTCTime` lastHb < (fromInteger . confTimeout) conf

    sendHeartbeatIfNeeded lastHbSent sock = do
      now <- getCurrentTime
      last <- readIORef lastHbSent
      when (now `diffUTCTime` last > 1) $ do
        send sock [] $ B8.pack "SYSTEM#HEARTBEAT"
        writeIORef lastHbSent now

    addCertificate zap clientCertPath = do
      eClientCert <- loadCertificateFromFile clientCertPath
      case eClientCert of
        Left err -> errorM "main" $ "Unable to load client certificate: " ++ clientCertPath
        Right clientCert -> zapAddClientCertificate zap "global" clientCert


