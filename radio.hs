import Prelude hiding (catch)

import Network
import System.IO
import System.IO.Error (isEOFError)
import Control.Exception (finally, catch, Exception(..))
import qualified Data.ByteString.Lazy as BSL
import qualified Data.ByteString as BS

import qualified Media.Streaming.GStreamer as Gst
import qualified System.Glib as G
import qualified System.Glib.MainLoop as G
import qualified System.Glib.Properties as G
import qualified System.Glib.GError as G
import qualified System.Glib.Signals as G

import System.Posix.IO

import System.Exit
import Text.Printf
import Data.Maybe

import Control.Concurrent
import Control.Monad

import GHC.Word

mkElement action =
    do element <- action
       case element of
         Just element' ->
             return element'
         Nothing -> 
             do hPutStrLn stderr "could not create all GStreamer elements\n"
                exitFailure

kalxGet = "GET /kalx-128.mp3 HTTP/1.0\r\nHostname: icecast.media.berkeley.edu\r\nUser-Agent: eklitzke-haskell\r\n\r\n"

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
    
    --createNamedPipe "/tmp/radio.fifo" namedPipeMode

    sock <- connectTo "icecast.media.berkeley.edu" $ PortNumber 8000
    writeHTTPRequest sock kalxGet
    skipResponseHeaders sock

    fif <- openFile "/tmp/radio.fifo" ReadWriteMode

    myThreadId <- forkIO $ writeToFifo sock fif

    Gst.init
    mainLoop <- G.mainLoopNew Nothing True

    pipeline <- Gst.pipelineNew "audio-player"
    source <- mkElement $ Gst.elementFactoryMake "filesrc" $ Just "file-source"
    decoder <- mkElement $ Gst.elementFactoryMake "mad" $ Just "mad-decoder"
    conv <- mkElement $ Gst.elementFactoryMake "audioconvert" $ Just "convert"
    sink <- mkElement $ Gst.elementFactoryMake "pulsesink" $ Just "pulse-output"

    let elements = [source, decoder, conv, sink]

    G.objectSetPropertyString "location" source "/tmp/radio.fifo"

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

    mapM_ (Gst.binAdd $ Gst.castToBin pipeline) elements

    Gst.elementLink source decoder
    Gst.elementLink decoder conv
    Gst.elementLink conv sink

    flip G.timeoutAdd 100 $ return True

    Gst.elementSetState pipeline Gst.StatePlaying

    G.mainLoopRun mainLoop

    Gst.elementSetState pipeline Gst.StateNull

    return ()
