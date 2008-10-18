-- Simple program to play an Internet radio stream using the GHC GStreamer
-- bindings. Most of the GStreamer boilerplate was copied from the demo app in
-- the gtk2hs source code.
--
-- For now, the steam must be of mpeg audio (i.e. mp3).

import Network
import System.IO
import qualified Data.ByteString.Lazy as BS

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
    ++ "User-Agent: radio-player <http://github.com/eklitzke/radio-player>\r\n\r\n" )

-- skip over HTTP headers
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

-- Read from a handle (lazily) and write it out to another handle (eagerly).
-- This is meant to be called as a separate thread with forkIO
writeToFifo :: Handle -> Handle -> IO ()
writeToFifo sock out = do
    s <- BS.hGetContents sock
    BS.hPutStr out s

main = do
    -- Parse the command line options. Two formats are accepted:
    --  1) radio <preset-name>
    --  2) radio <domain> <path> <port>
    args <- getArgs
    [domain, path, port] <- return $ case args of
        [s] -> case s of
            "digitalis" -> ["fx.somafm.com", "/", "8900"]
            "groovesalad" -> ["fx.somafm.com", "/", "8032"]
            "kalx" -> ["icecast.media.berkeley.edu", "/kalx-128.mp3", "8000"]
        _ -> args

    -- Create a named pipe if it doesn't exist. For some reason, this doesn't
    -- work right on my laptop (no matter what I do, the file created doesn't
    -- have the fifo bit). For now, you just need to create it yourself with
    -- mkfifo.
    exists <- fileExist fifoName
    if exists
        then return $ Left ()
        else return $ Right $ createNamedPipe fifoName fifoMode

    -- Connect to the mpeg stream, and get ready to read mpeg data
    sock <- connectTo domain $ PortNumber $ fromIntegral (read port :: Int)
    writeHTTPRequest sock $ makeHTTPRequest domain path
    skipResponseHeaders sock

    -- Open the named pipe in read/write mode
    fifo <- openFile fifoName ReadWriteMode

    -- Copy the contents of the socket to the named pipe in a separate "thread"
    myThreadId <- forkIO $ writeToFifo sock fifo

    -- GStreamer boilerplate
    Gst.init
    mainLoop <- G.mainLoopNew Nothing True

    pipeline <- Gst.pipelineNew "audio-player"
    source <- mkElement $ Gst.elementFactoryMake "filesrc" $ Just "file-source"
    decoder <- mkElement $ Gst.elementFactoryMake "mad" $ Just "mad-decoder"
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

    mapM_ (Gst.binAdd $ Gst.castToBin pipeline) [source, decoder, sink]

    Gst.elementLink source decoder
    Gst.elementLink decoder sink

    G.timeoutAdd (return True) 100

    Gst.elementSetState pipeline Gst.StatePlaying

    G.mainLoopRun mainLoop

    Gst.elementSetState pipeline Gst.StateNull
