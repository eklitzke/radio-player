import Network
import System.IO
import qualified Data.ByteString.Lazy as BSL

import System.Environment

import qualified Media.Streaming.GStreamer as Gst
import qualified System.Glib as G
import qualified System.Glib.MainLoop as G
import qualified System.Glib.Properties as G

import System.Posix.Files
import System.Posix.Types

import System.Exit
import Data.Maybe

import Control.Concurrent

(.|.) = unionFileModes

fifoName :: String
fifoName = "/tmp/radio-player.fifo"

-- The mode for a fifo with perms prw------- (on Linux, 10600)
fifoMode :: FileMode
fifoMode = namedPipeMode .|. ownerReadMode .|. ownerWriteMode
--fifoMode = ownerReadMode .|. ownerWriteMode

mkElement action =
    do element <- action
       case element of
         Just element' ->
             return element'
         Nothing -> 
             do hPutStrLn stderr "could not create all GStreamer elements\n"
                exitFailure

makeHTTPRequest :: String -> String -> String
makeHTTPRequest domain path = (
       "GET " ++ path ++ " HTTP/1.0\r\n"
    ++ "Hostname: " ++ domain ++ "\r\n"
    ++ "User-Agent: radio-player-haskell\r\n\r\n" )

kalxGet = "GET /kalx-128.mp3 HTTP/1.0\r\nHostname: icecast.media.berkeley.edu\r\nUser-Agent: eklitzke-haskell\r\n\r\n"

digitalisGet = "GET / HTTP/1.0\r\nHostname: fx.somafm.com\r\nUser-Agent: eklitzke-haskell\r\n\r\n"

-- skip over the HTTP headers
skipResponseHeaders :: Handle -> IO ()
skipResponseHeaders hdl = do
    ln <- hGetLine hdl
    case ln of
        "\r" -> return ()
        _    -> skipResponseHeaders hdl

writeHTTPRequest :: Handle -> String -> IO ()
writeHTTPRequest sock s = do
    hPutStr sock s
    hFlush sock

writeToFifo :: Handle -> Handle -> IO ()
writeToFifo sock out = do
    s <- BSL.hGetContents sock
    BSL.hPutStr out $! s

main = do

    args <- getArgs
    [domain, path, port] <- case args of
        [s] -> return $ case s of
            "kalx" -> ["icecast.media.berkeley.edu", "/kalx-128.mp3", "8000"]
            "digitalis" -> ["fx.somafm.com", "/", "8900"]
        _ -> return args

    exists <- fileExist fifoName
    if exists
        then return $ Left ()
        else return $ Right $ createNamedPipe fifoName fifoMode

    let httpReq = makeHTTPRequest domain path

    --sock <- connectTo "icecast.media.berkeley.edu" $ PortNumber 8000
    --writeHTTPRequest sock kalxGet
    sock <- connectTo domain $ PortNumber $ fromIntegral (read port :: Int)
    writeHTTPRequest sock httpReq
    skipResponseHeaders sock

    fifo <- openFile fifoName ReadWriteMode
    --fifo <- openFile "/tmp/radio.fifo" ReadWriteMode

    myThreadId <- forkIO $ writeToFifo sock fifo

    Gst.init
    mainLoop <- G.mainLoopNew Nothing True

    pipeline <- Gst.pipelineNew "audio-player"
    source <- mkElement $ Gst.elementFactoryMake "filesrc" $ Just "file-source"
    decoder <- mkElement $ Gst.elementFactoryMake "mad" $ Just "mad-decoder"
    conv <- mkElement $ Gst.elementFactoryMake "audioconvert" $ Just "convert"
    sink <- mkElement $ Gst.elementFactoryMake "pulsesink" $ Just "pulse-output"

    G.objectSetPropertyString "location" source fifoName

    bus <- Gst.pipelineGetBus (Gst.castToPipeline pipeline)
    Gst.busAddWatch bus G.priorityDefault $ \bus message ->
        do case Gst.messageType message of
            Gst.MessageEOS ->
                do putStrLn "end of stream"
                   G.mainLoopQuit mainLoop
            Gst.MessageError ->
                let G.GError _ _ msg = fst $ fromJust $ Gst.messageParseError message
                    messageStr = "Error: " ++ msg
                in do hPutStrLn stderr messageStr
                      G.mainLoopQuit mainLoop
            _ -> return ()
           return True

    mapM_ (Gst.binAdd $ Gst.castToBin pipeline) [source, decoder, conv, sink]

    Gst.elementLink source decoder
    Gst.elementLink decoder conv
    Gst.elementLink conv sink

    G.timeoutAdd (return True) 100

    Gst.elementSetState pipeline Gst.StatePlaying

    G.mainLoopRun mainLoop

    Gst.elementSetState pipeline Gst.StateNull
