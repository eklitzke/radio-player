import Prelude hiding (catch)

import Network
import System.IO
import System.IO.Error (isEOFError)
import Control.Exception (finally, catch, Exception(..))
import qualified Data.ByteString.Lazy as BSL

import Media.Streaming.GStreamer

kalxGet = "GET /kalx-128.mp3 HTTP/1.0\r\nHostname: icecast.media.berkeley.edu\r\nUser-Agent: eklitzke-haskell\r\n\r\n"

-- skip over the HTTP headers
skipHeaders :: Handle -> IO ()
skipHeaders hdl = do
    ln <- hGetLine hdl
    case ln of
        "\r" -> return ()
        _    -> skipHeaders hdl

main = do
    sock <- connectTo "icecast.media.berkeley.edu" $ PortNumber 8000
    hPutStr sock kalxGet
    hFlush sock
    skipHeaders sock
    song <- BSL.hGetContents sock
    BSL.putStr song
