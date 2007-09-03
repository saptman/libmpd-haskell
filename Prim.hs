{-
    libmpd for Haskell, an MPD client library.
    Copyright (C) 2005-2007  Ben Sinclair <bsinclai@turing.une.edu.au>

    This library is free software; you can redistribute it and/or
    modify it under the terms of the GNU Lesser General Public
    License as published by the Free Software Foundation; either
    version 2.1 of the License, or (at your option) any later version.

    This library is distributed in the hope that it will be useful,
    but WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
    Lesser General Public License for more details.

    You should have received a copy of the GNU Lesser General Public
    License along with this library; if not, write to the Free Software
    Foundation, Inc., 51 Franklin St, Fifth Floor, Boston, MA  02110-1301  USA
-}

-- | Module    : Prim
-- Copyright   : (c) Ben Sinclair 2005-2007
-- License     : LGPL
-- Maintainer  : bsinclai@turing.une.edu.au
-- Stability   : alpha
-- Portability : Haskell 98
--
-- Core functionality.

module Prim (

             -- * Data types
             MPD, ACK(..), ACKType(..),

             -- * Running an action
             withMPDEx,

             -- * Errors
             throwMPD, catchMPD,

             -- * Interacting
             getResponse, clearerror, close, reconnect, kill,

             module Control.Monad.Trans
            ) where

import Control.Monad (liftM, unless)
import Control.Exception (finally)
import Control.Monad.Trans
import Prelude hiding (repeat)
import Data.IORef (IORef, newIORef, readIORef, writeIORef)
import Data.List (isPrefixOf)
import Data.Maybe
import Network
import System.IO
import System.IO.Error (isEOFError)

--
-- Data types.
--

-- | A connection to an MPD server.
-- don't export the field names.
data Connection = Conn { connHostName :: String
                       , connPortNum  :: Integer
                       , connHandle   :: IORef (Maybe Handle)
                       , connGetPass  :: IO (Maybe String)
                       }

-- | The ACK type is used to signal errors, both from the MPD and otherwise.
data ACK = NoMPD              -- ^ MPD not responding
         | TimedOut           -- ^ The connection timed out
         | Custom String      -- ^ Used for misc. errors
         | ACK ACKType String -- ^ ACK type and a message from the server.

instance Show ACK where
    show NoMPD      = "Could not connect to MPD"
    show TimedOut   = "MPD connection timed out"
    show (Custom s) = s
    show (ACK _ s)  = s

-- | Represents various MPD errors (aka. ACKs).
data ACKType = InvalidArgument  -- ^ Invalid argument passed (ACK 2)
             | InvalidPassword  -- ^ Invalid password supplied (ACK 3)
             | Auth             -- ^ Authentication required (ACK 4)
             | UnknownCommand   -- ^ Unknown command (ACK 5)
             | FileNotFound     -- ^ File or directory not found ACK 50)
             | PlaylistMax      -- ^ Playlist at maximum size (ACK 51)
             | System           -- ^ A system error (ACK 52)
             | PlaylistLoad     -- ^ Playlist loading failed (ACK 53)
             | Busy             -- ^ Update already running (ACK 54)
             | NotPlaying       -- ^ An operation requiring playback
                                --   got interrupted (ACK 55)
             | FileExists       -- ^ File already exists (ACK 56)
             | UnknownACK       -- ^ An unknown ACK (aka. bug)

-- Export the type name but not the constructor or the field.
--
-- This is basically a state and an error monad combined. It's just
-- nice if we can have a few custom functions that fiddle with the
-- internals.
newtype MPD a = MPD { runMPD :: Connection -> IO (Either ACK a) }

instance Functor MPD where
    fmap f m = MPD $ \conn -> either Left (Right . f) `liftM` runMPD m conn

instance Monad MPD where
    return a = MPD $ \_ -> return (Right a)
    m >>= f  = MPD $ \conn -> runMPD m conn >>=
                              either (return . Left) (flip runMPD conn . f)
    fail err = MPD $ \_ -> return . Left $ Custom err

instance MonadIO MPD where
    liftIO m = MPD $ \_ -> liftM Right m

-- | Throw an exception.
throwMPD :: ACK -> MPD ()
throwMPD e = MPD $ \_ -> return (Left e)

-- | Catch an exception from an action.
catchMPD :: MPD a -> (ACK -> MPD a) -> MPD a
catchMPD m h = MPD $ \conn ->
    runMPD m conn >>= either (flip runMPD conn . h) (return . Right)

{-
--
-- Basic connection functions
--
-}

-- | Run an MPD action against a server.
withMPDEx :: String            -- ^ Host name.
          -> Integer           -- ^ Port number.
          -> IO (Maybe String) -- ^ An action that supplies passwords.
          -> MPD a             -- ^ The action to run.
          -> IO (Either ACK a)
withMPDEx host port getpw m = do
    hRef <- newIORef Nothing
    connect host port hRef
    readIORef hRef >>= maybe (return $ Left NoMPD)
        (\_ -> finally (runMPD m (Conn host port hRef getpw)) (closeIO hRef))

-- Connect to an MPD server.
connect :: String -> Integer -- host and port
        -> IORef (Maybe Handle) -> IO ()
connect host port hRef =
    withSocketsDo $ do
        closeIO hRef
        --handle <- connectTo host . PortNumber $ fromInteger port
        handle <- safeConnectTo host port
        writeIORef hRef handle
        maybe (return ()) (\h -> checkConn h >>= flip unless (closeIO hRef))
              handle

safeConnectTo :: String -> Integer -> IO (Maybe Handle)
safeConnectTo host port =
    catch (liftM Just $ connectTo host (PortNumber $ fromInteger port))
          (const $ return Nothing)

-- Check that an MPD daemon is at the other end of a connection.
checkConn :: Handle -> IO Bool
checkConn h = isPrefixOf "OK MPD" `liftM` hGetLine h

-- Close a connection.
closeIO :: IORef (Maybe Handle) -> IO ()
closeIO hRef = do
    readIORef hRef >>= maybe (return ())
                             (\h -> hPutStrLn h "close" >> hClose h)
    writeIORef hRef Nothing

-- | Refresh a connection.
reconnect :: MPD ()
reconnect = MPD $ \(Conn host port hRef _) -> do
    connect host port hRef
    liftM (maybe (Left NoMPD) (const $ Right ())) (readIORef hRef)

-- XXX this doesn't use the password supplying feature.
--
-- | Kill the server. Obviously, the connection is then invalid.
kill :: MPD ()
kill = MPD $ \conn -> do
    readIORef (connHandle conn) >>=
        maybe (return ()) (\h -> hPutStrLn h "kill" >> hClose h)
    writeIORef (connHandle conn) Nothing
    return (Left NoMPD)

-- XXX this doesn't use the password supplying feature.
--
-- | Clear the current error message in status.
clearerror :: MPD ()
clearerror = MPD $ \conn -> do
    readIORef (connHandle conn) >>= maybe (return $ Left NoMPD)
        (\h -> hPutStrLn h "clearerror" >> hFlush h >> return (Right ()))

-- | Close an MPD connection.
close :: MPD ()
close = MPD $ \conn -> closeIO (connHandle conn) >> return (Right ())

-- | Send a command to the MPD and return the result.
getResponse :: String -> MPD [String]
getResponse cmd = MPD $ \conn -> do
    readIORef (connHandle conn) >>=
        maybe (return $ Left NoMPD)
              (\h -> hPutStrLn h cmd >> hFlush h >>
                     loop h (tryPassword conn (getResponse cmd)) [])
    where loop h tryPw acc = do
              getln h (\l -> parseResponse (loop h tryPw) l acc >>= either
                          (\x -> case x of
                                      ACK Auth _ -> tryPw
                                      _          -> return $ Left x)
                          (return . Right))
          getln h cont =
              catch (liftM Right $ hGetLine h) (return . Left) >>=
                  either (\e -> if isEOFError e then return (Left TimedOut)
                                                else ioError e)
                         cont

-- Send a password to MPD and run an action on success, return an ACK
-- on failure.
tryPassword :: Connection
            -> MPD a  -- run on success
            -> IO (Either ACK a)
tryPassword conn cont = do
    readIORef (connHandle conn) >>= maybe (return $ Left NoMPD)
        (\h -> connGetPass conn >>= maybe (return . Left $
                                            ACK Auth "Password required")
                   (\pw -> do hPutStrLn h ("password " ++ pw) >> hFlush h
                              result <- hGetLine h
                              case result of "OK" -> runMPD cont conn
                                             _    -> tryPassword conn cont))

-- Break an ACK into (error code, current command, message).
-- ACKs are of the form:
-- ACK [error@command_listNum] {current_command} message_text\n
splitAck :: String -> (String, String, String)
splitAck s = (code, cmd, msg)
    where (code, notCode) = between (== '[') (== '@') s
          (cmd, notCmd)   = between (== '{') (== '}') notCode
          msg             = drop 1 . snd $ break (== ' ') notCmd

          -- take whatever is between 'f' and 'g'.
          between f g xs  = let (_, y) = break f xs
                            in break g (drop 1 y)

parseAck :: String -> ACK
parseAck s = ACK ack msg

    where
        ack = case code of
                "2"  -> InvalidArgument
                "3"  -> InvalidPassword
                "4"  -> Auth
                "5"  -> UnknownCommand
                "50" -> FileNotFound
                "51" -> PlaylistMax
                "52" -> System
                "53" -> PlaylistLoad
                "54" -> Busy
                "55" -> NotPlaying
                "56" -> FileExists
                _    -> UnknownACK
        (code, _, msg) = splitAck s

-- Consume response and return a Response.
parseResponse :: ([String] -> IO (Either ACK [String]))
              -> String -> [String] -> IO (Either ACK [String])
parseResponse f s acc
    | isPrefixOf "ACK" s = return . Left $ parseAck s
    | isPrefixOf "OK" s  = return . Right $ reverse acc
    | otherwise          = f (s:acc)
