module Discord.Internal.Voice
    ( joinVoice
    , leaveVoice
    , updateSpeakingStatus
    , playPCM
    , playFFmpeg
    , playYTDL
    , DiscordVoiceHandle(..)
    ) where

import           Codec.Audio.Opus.Encoder
import           Control.Concurrent.Async           ( race
                                                    )
import qualified Control.Concurrent.BoundedChan as Bounded
import           Control.Concurrent                 ( ThreadId
                                                    , threadDelay
                                                    , killThread
                                                    , forkIO
                                                    , Chan
                                                    , dupChan
                                                    , newChan
                                                    , readChan
                                                    , writeChan
                                                    , MVar
                                                    , newEmptyMVar
                                                    , newMVar
                                                    , readMVar
                                                    , putMVar
                                                    , withMVar
                                                    , tryPutMVar
                                                    )
import           Control.Exception.Safe             ( SomeException
                                                    , handle
                                                    )
import           Control.Lens.Operators             ( (#)
                                                    )
import           Control.Monad.Reader               ( ask
                                                    , liftIO
                                                    )
import           Control.Monad                      ( when
                                                    , void
                                                    )
import           Data.Aeson
import           Data.Aeson.Types                   ( parseMaybe
                                                    )
import qualified Data.ByteString.Lazy as BL
import           Data.Maybe                         ( fromJust
                                                    )
import qualified Data.Text as T
import           System.Process                     ( CreateProcess(..)
                                                    , StdStream(..)
                                                    , proc
                                                    , createProcess
                                                    )

import           Discord.Internal.Types             ( GuildId
                                                    , ChannelId
                                                    , Event
                                                    , GatewaySendable(..)
                                                    , UpdateStatusVoiceOpts
                                                    )
import           Discord.Internal.Voice.WebsocketLoop
import           Discord.Internal.Voice.UDPLoop
import           Discord.Internal.Types.VoiceWebsocket
import           Discord.Internal.Types.VoiceUDP
import           Discord.Internal.Types.VoiceError
import           Discord.Internal.Types             ( GuildId
                                                    , UserId
                                                    , User(..)
                                                    , UpdateStatusVoiceOpts(..)
                                                    , Event( UnknownEvent )
                                                    )
import           Discord.Internal.Gateway.EventLoop ( GatewayException(..)
                                                    )
import           Discord.Internal.Gateway.Cache     ( Cache(..)
                                                    )
import           Discord.Handle                     ( discordHandleGateway
                                                    , discordHandleLog
                                                    )
import           Discord                            ( DiscordHandler
                                                    , sendCommand
                                                    , readCache
                                                    )

data DiscordVoiceThreadId
    = DiscordVoiceThreadIdWebsocket ThreadId
    | DiscordVoiceThreadIdUDP ThreadId

data DiscordVoiceHandle = DiscordVoiceHandle
    { discordVoiceGuildId           :: GuildId
    , discordVoiceHandleWebsocket   :: DiscordVoiceHandleWebsocket
    , discordVoiceHandleUDP         :: DiscordVoiceHandleUDP
    , discordVoiceSSRC              :: Integer
    , discordVoiceThreads           :: [DiscordVoiceThreadId]
    , discordVoiceMutEx             :: MVar ()
    }

-- | Send a Gateway Websocket Update Voice State command (Opcode 4). Used when
-- the client wants to join, move, or disconnect from a voice channel.
updateStatusVoice
    :: GuildId
    -- ^ Id of Guild
    -> Maybe ChannelId
    -- ^ Id of the voice channel client wants to join (Nothing if disconnecting)
    -> Bool
    -- ^ Is the client muted
    -> Bool
    -- ^ Is the client deafened
    -> DiscordHandler ()
updateStatusVoice a b c d = sendCommand $ UpdateStatusVoice $ UpdateStatusVoiceOpts a b c d

-- | Joins a voice channel and initialises all the threads, ready to stream.
--
-- @
-- eVc <- joinVoice gid cid False False
-- case eVc of
--     Left e -> liftIO $ putStrLn $ show e
--     Right vc -> do
--         -- do nothing in VC for 30 seconds
--         threadDelay $ 30 * 10**(6 :: Int)
--         'leaveVoice' vc
-- @
joinVoice
    :: GuildId
    -- ^ The guild in which the channel is located
    -> ChannelId
    -- ^ The voice channel id to join
    -> Bool
    -- ^ Whether the bot should join muted
    -> Bool
    -- ^ Whether the bot should join deafened
    -> DiscordHandler (Either VoiceError DiscordVoiceHandle)
joinVoice gid cid mute deaf = do
    h <- ask
    -- Duplicate the event channel, so we can read without taking data from event handlers
    let (_events, _, _) = discordHandleGateway h
    events <- liftIO $ dupChan _events

    -- Send opcode 4 in Gateway
    updateStatusVoice gid (Just cid) mute deaf

    -- Wait for Opcode 0 Voice State Update and Voice Server Update
    -- for a maximum of 5 seconds
    result <- liftIO $ doOrTimeout 5 (waitOpcode2And4 events)

    case result of
        Nothing -> do
            -- did not respond in time: no permission? or discord offline?
            pure $ Left VoiceNotAvailable
        Just (_, (_, _, Nothing)) -> do
            -- If endpoint is null, according to Docs, no servers are available.
            pure $ Left NoServerAvailable
        Just (sessionId, (token, guildId, Just endpoint)) -> do
            let connInfo = WSConnInfo sessionId token guildId endpoint
            -- Get the current user ID, and pass it on with all the other data
            uid <- getCacheUserId
            liftIO $ startVoiceThreads connInfo events uid $ discordHandleLog h

-- | Get the user ID of the bot from the cache.
getCacheUserId :: DiscordHandler UserId
getCacheUserId = userId . _currentUser <$> readCache

-- | Perform an IO action for a maximum of @sec@ seconds.
doOrTimeout :: Int -> IO a -> IO (Maybe a)
doOrTimeout sec longAction = rightToMaybe <$> race waitSecs longAction
  where
    waitSecs :: IO ()
    waitSecs = threadDelay (sec * 10^(6 :: Int))

-- | Selects the right element as a Maybe
rightToMaybe :: Either a b -> Maybe b
rightToMaybe (Left _)  = Nothing
rightToMaybe (Right x) = Just x

-- | Loop until both VOICE_STATE_UPDATE and VOICE_SERVER_UPDATE are received.
-- The order is undefined in docs, so this function will recursively fill
-- up two Maybe arguments until both are Just.
waitOpcode2And4
    :: Chan (Either GatewayException Event)
    -> IO (T.Text, (T.Text, GuildId, Maybe T.Text))
waitOpcode2And4 events = loopForBoth Nothing Nothing
  where
    loopForBoth
        :: Maybe T.Text
        -> Maybe (T.Text, GuildId, Maybe T.Text)
        -> IO (T.Text, (T.Text, GuildId, Maybe T.Text))
    loopForBoth (Just a) (Just (b, c, d)) = pure (a, (b, c, d))
    loopForBoth mb1 mb2 = do
        top <- readChan events
        case top of
            -- Parse UnknownEvent, which are events not handled by discord-haskell.
            Right (UnknownEvent "VOICE_STATE_UPDATE" obj) -> do
                -- Conveniently, we can just pass the result of parseMaybe
                -- back recursively.
                let sessionId = flip parseMaybe obj $ \o -> do
                        o .: "session_id"
                loopForBoth sessionId mb2
            Right (UnknownEvent "VOICE_SERVER_UPDATE" obj) -> do
                let result = flip parseMaybe obj $ \o -> do
                        token <- o .: "token"
                        guildId <- o .: "guild_id"
                        endpoint <- o .: "endpoint"
                        pure (token, guildId, endpoint)
                loopForBoth mb1 result
            _ -> loopForBoth mb1 mb2

-- | Start the Websocket thread, which will create the UDP thread
startVoiceThreads
    :: WebsocketConnInfo
    -- ^ Connection details for the websocket
    -> Chan (Either GatewayException Event)
    -- ^ Gateway events
    -> UserId
    -- ^ The current user ID
    -> Chan T.Text
    -- ^ The channel to log errors
    -> IO (Either VoiceError DiscordVoiceHandle)
startVoiceThreads connInfo gatewayEvents uid log = do
    -- First create the websocket (which will automatically try to identify)
    events <- newChan -- types are inferred from line below
    sends <- newChan
    syncKey <- newEmptyMVar
    websocketId <- forkIO $ voiceWebsocketLoop gatewayEvents (events, sends) (connInfo, uid) log

    -- The first event is either a Right (Ready payload) or Left errors
    e <- readChan events
    case e of
        Right (Ready p) -> do
            -- Now try to create the UDP thread
            let udpInfo = UDPConnInfo
                    { udpInfoSSRC = readyPayloadSSRC p
                    , udpInfoAddr = readyPayloadIP p
                    , udpInfoPort = readyPayloadPort p
                    , udpInfoMode = "xsalsa20_poly1305"
                    -- ^ Too much hassle to implement all encryption modes.
                    }

            byteReceives <- newChan
            byteSends <- Bounded.newBoundedChan 500 -- 10 seconds worth of 20ms
            udpId <- forkIO $ udpLoop (byteReceives, byteSends) udpInfo syncKey log

            -- the first packet is a IP Discovery response.
            (IPDiscovery _ ip port) <- readChan byteReceives

            -- signal to the voice websocket using Opcode 1 Select Protocol
            writeChan sends $ SelectProtocol $ SelectProtocolPayload
                { selectProtocolPayloadProtocol = "udp"
                , selectProtocolPayloadIP       = ip
                , selectProtocolPayloadPort     = port
                , selectProtocolPayloadMode     = "xsalsa20_poly1305"
                }

            -- the next thing we receive in the websocket *should* be an
            -- Opcode 4 Session Description
            f <- readChan events
            case f of
                Right (SessionDescription _ key) -> do
                    putMVar syncKey key
                    mutex <- newMVar ()
                    pure $ Right $ DiscordVoiceHandle
                        { discordVoiceGuildId         = wsInfoGuildId connInfo
                        , discordVoiceHandleWebsocket = (events, sends)
                        , discordVoiceHandleUDP       = (byteReceives, byteSends)
                        , discordVoiceSSRC            = udpInfoSSRC udpInfo
                        , discordVoiceThreads         =
                            [ DiscordVoiceThreadIdWebsocket websocketId
                            , DiscordVoiceThreadIdUDP udpId
                            ]
                        , discordVoiceMutEx           = mutex
                        }
                Right a -> do
                    -- If this is ever called, refactor this entire case stmt
                    -- to a waitForSessionDescription, as it means another
                    -- event could be in the Websocket before SessionDescription
                    print "owo"
                    print a
                    killThread udpId
                    killThread websocketId
                    pure $ Left $ InvalidPayloadOrder
                Left  _ -> do
                    killThread udpId
                    killThread websocketId
                    pure $ Left $ InvalidPayloadOrder
        Right _ -> do
            killThread websocketId
            pure $ Left $ InvalidPayloadOrder
        Left  _ -> do
            killThread websocketId
            pure $ Left $ InvalidPayloadOrder

-- | Leave the current voice session by killing all relevant threads, and
-- sending a Voice State Update to the gateway.
leaveVoice :: DiscordVoiceHandle -> DiscordHandler ()
leaveVoice handle = do
    mapM_ (liftIO . killThread . toId) (discordVoiceThreads handle)
    updateStatusVoice (discordVoiceGuildId handle) Nothing False False
    void $ liftIO $ tryPutMVar (discordVoiceMutEx handle) ()
  where
    toId t = case t of
        DiscordVoiceThreadIdWebsocket a -> a
        DiscordVoiceThreadIdUDP a -> a

-- | Helper function to update the speaking indicator for the bot.
--
-- Soundshare and priority are const as False, don't see bots needing them.
-- If and when required, add Bool signatures to this function.
updateSpeakingStatus :: DiscordVoiceHandle -> Bool -> IO ()
updateSpeakingStatus handle micStatus =
    writeChan (snd $ discordVoiceHandleWebsocket handle) $ Speaking $ SpeakingPayload
        { speakingPayloadMicrophone = micStatus
        , speakingPayloadSoundshare = False
        , speakingPayloadPriority   = False
        , speakingPayloadDelay      = 0
        , speakingPayloadSSRC       = (discordVoiceSSRC handle)
        }

-- | Play a PCM audio until finish.
--
-- Requires no external dependencies, as it uses FFI to encode opus (through the
-- "Codec.Audio.Opus" module).
--
-- @
-- eVc <- joinVoice gid cid False False
-- case eVc of
--     Left e -> pure ()
--     Right vc -> do
--         music <- BL.readFile "things.pcm"
--         playPCM vc music
--         'leaveVoice' vc
-- @
playPCM
    :: DiscordVoiceHandle
    -> BL.ByteString
    -- ^ The 16-bit little-endian stereo PCM, at 48kHz.
    -> DiscordHandler ()
playPCM handle source =
    liftIO $ withMVar (discordVoiceMutEx handle) $ \_ -> do
        -- update the speaking indicator (this needs to happen before bytes are sent)
        updateSpeakingStatus handle True

        let enCfg = _EncoderConfig # (opusSR48k, True, app_audio)
        -- 1275 is the max bytes an opus 20ms frame can have
        let enStreamCfg = _StreamConfig # (enCfg, 48*20, 1276)
        encoder <- opusEncoderCreate enCfg
        repeatedlySend encoder enStreamCfg source

  where
    repeatedlySend encoder streamCfg restSource = do
        let sends = snd (discordVoiceHandleUDP handle)
        if not (BL.null restSource) then do
            -- bytestrings are made of CChar (Int8) but the data is 16-bit so
            -- multiply by two to get the right amount
            let clipLength = 48*20*2*2 -- frame size * channels * (16/8)
            let (clip, remains) = BL.splitAt clipLength restSource
            -- encode the audio
            encoded <- opusEncode encoder streamCfg $ BL.toStrict clip
            -- send it
            Bounded.writeChan sends encoded
            repeatedlySend encoder streamCfg remains
        else do
            -- Send at least 5 blank frames (10 just in case)
            sequence_ $ replicate 10 $ Bounded.writeChan sends "\248\255\254"
            updateSpeakingStatus handle False

-- | Play any type of audio that FFmpeg supports, by launching a FFmpeg
-- subprocess and reading the stdout stream lazily.
--
-- __Requires the ffmpeg executable.__
-- @
-- eVc <- joinVoice gid cid False False
-- case eVc of
--     Left e -> pure ()
--     Right vc -> do
--         playFFmpeg vc "awesome.mp3" "ffmpeg"
--         'leaveVoice' vc
-- @
playFFmpeg
    :: DiscordVoiceHandle
    -> FilePath
    -- ^ The file to play
    -> String
    -- ^ The ffmpeg executable
    -> DiscordHandler ()
playFFmpeg handle fp exe =
    liftIO $ withMVar (discordVoiceMutEx handle) $ \_ -> do
        -- update the speaking indicator (this needs to happen before bytes are sent)
        updateSpeakingStatus handle True

        -- Flags taken from discord.py, thanks.
        (_, Just stdout, _, ph) <- createProcess (proc exe
            [ "-reconnect", "1"
            , "-reconnect_streamed", "1"
            , "-reconnect_delay_max", "2"
            , "-i", fp
            , "-f", "s16le"
            , "-ar", "48000"
            , "-ac", "2"
            , "-loglevel", "warning"
            , "pipe:1"
            ]) { std_out = CreatePipe }

        -- Initialise encoder
        let enCfg = _EncoderConfig # (opusSR48k, True, app_audio)
        let enStreamCfg = _StreamConfig # (enCfg, 48*20, 1276)
        encoder <- opusEncoderCreate enCfg
        repeatedlySend encoder enStreamCfg stdout

  where
    repeatedlySend encoder streamCfg stdoutHandle = do
        let sends = snd (discordVoiceHandleUDP handle)
        -- pretty much the same as playPCM, see there for more info
        let clipLength = 48*20*2*2 -- frame size * channels * (16/8)
        source <- BL.hGet stdoutHandle clipLength
        if not (BL.null source)
            then do
                encoded <- opusEncode encoder streamCfg $ BL.toStrict source
                Bounded.writeChan sends encoded
                repeatedlySend encoder streamCfg stdoutHandle
            else do
                -- Send at least 5 blank frames (10 just in case)
                sequence_ $ replicate 10 $ Bounded.writeChan sends "\248\255\254"
                updateSpeakingStatus handle False

-- | Play any URL that is supported by youtube-dl, or a search query for YouTube.
-- Extracts the stream URL using "youtube-dl -j", and passes it to playFFmpeg.
--
-- __Requires the youtube-dl and ffmpeg executable.__
playYTDL
    :: DiscordVoiceHandle
    -> String
    -- ^ The url or search query to play with youtube-dl.
    -> String
    -- ^ The youtube-dl executable
    -> String
    -- ^ The ffmpeg executable
    -> DiscordHandler ()
playYTDL handle query exe ffmpegexe = do
    (_, Just stdout, _, ph) <- liftIO $ createProcess (proc exe
        [ "-j"
        , "--default-search", "ytsearch"
        , "--format", "bestaudio/best"
        , query
        ]) { std_out = CreatePipe }

    -- read all of it lazily
    extractedInfo <- liftIO $ BL.hGetContents stdout

    -- extract stream url, send to playFFmpeg
    let perhapsUrl = do
            result <- decode extractedInfo
            flip parseMaybe result $ \obj -> obj .: "url"
    case perhapsUrl of
        -- no matching url found
        Nothing -> pure ()
        Just url ->
            playFFmpeg handle url ffmpegexe
