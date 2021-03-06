
{-# LANGUAGE OverloadedStrings, ScopedTypeVariables, RecordWildCards #-}

module WebUI ( webUIStart
             , LightUpdate(..)
             , LightUpdateTChan
             ) where

import Text.Printf
import Data.Monoid
import Data.List
import qualified Data.Function (on)
import qualified Data.HashMap.Strict as HM
import qualified Data.HashSet as HS
import Control.Concurrent.STM
import Control.Concurrent.Async
import Control.Lens hiding ((#), set, (<.>), element)
import Control.Monad
import Control.Monad.Reader
import Control.Monad.State
import Data.Time.Clock
import qualified Graphics.UI.Threepenny as UI
import Graphics.UI.Threepenny.Core
import Text.Blaze.Html.Renderer.String
import qualified System.Info as SI
import Data.Char

import Util
import Trace
import AppDefs
import WebUIHelpers
import WebUITileBuilding
import WebUITileBuildingScenes
import WebUITileBuildingSchedules
import PersistConfig
import HueJSON (GroupName(..), Light(..))

-- Threepenny based user interface for inspecting and controlling Hue devices

webUIStart :: MonadIO m => AppEnv -> m ()
webUIStart ae = do
    -- Start server
    let port      = ae ^. aeCmdLineOpts . cloPort
        interface | ae ^. aeCmdLineOpts . cloOnlyLocalhost = "localhost"
                  | otherwise                              = "0.0.0.0"
    traceS TLInfo $ printf "Starting web server on %s, port %s" (show interface) (show port)
    liftIO . startGUI
        defaultConfig { jsPort                     = Just port
                      , jsAddr                     = Just interface
                      , jsLog                      = if   ae ^. aeCmdLineOpts . cloTraceHTTP
                                                     then traceB TLInfo
                                                     else \_ -> return ()
                      , jsStatic                   = Just "static"
                      , jsCustomHTML               = Just "dashboard.html"
                      , jsWindowReloadOnDisconnect = True
                      }
        $ setup ae

setup :: AppEnv -> Window -> UI ()
setup ae@AppEnv { .. } window = do
    start <- liftIO getCurrentTime
    -- Obtain user ID from cookie
    -- TODO: Round trip, would be nice to just get the cookie the normal way
    userID <- CookieUserID <$> (callFunction $ ffi "getUserID()" :: UI String)
    -- Get user data for user ID, create new data if none is present
    (newUser, userData) <- liftIO . atomically $ do
        pc <- readTVar _aePC
        case HM.lookup userID (pc ^. pcUserData) of
            Nothing -> do let ud = defaultUserData
                          writeTVar _aePC $
                              pc & pcUserData %~ (HM.insert userID ud)
                          return (True, ud)
            Just ud -> return (False, ud)
    traceS TLInfo $ "New connection from user ID '" <> fromCookieUserID userID <>
        ( if   newUser
          then "' (new user, creating default data), "
          else "' (known user), "
        )
    -- Read all scenes, schedules, lights and light groups, display sorted by name.
    (scenes, schedules, lights, lightGroupsList) <- liftIO . atomically $
      (,,,)
        <$> (sortBy (compare `Data.Function.on` fst) . HM.toList . _pcScenes    <$> readTVar _aePC)
        <*> (sortBy (compare `Data.Function.on` fst) . HM.toList . _pcSchedules <$> readTVar _aePC)
        <*> readTVar _aeLights
        <*> ( (sortBy (compare `Data.Function.on` fst) . HM.toList)
              <$> readTVar _aeLightGroups
            )
    -- Run PageBuilder monad, build list of HTML constructors and UI actions (event handlers)
    --
    -- TODO: Add a 'Help' tile with basic instructions, maybe only the first time
    -- TODO: Tile showing power / light usage over time
    -- TODO: Add support for a 'dark mode' theme
    -- TODO: Zoom buttons to make tiles larger / smaller
    -- TODO: Configuration tile, allow hiding / reordering of other tiles
    -- TODO: Generate placeholder divs for scenes and tiles, then fill their content
    --       later. This separation should allow for updating them without reloading
    --       the entire page
    -- TODO: The contrast for disabled tiles is not great, making it both difficult to
    --       read them and to distinguish them from enabled ones. Having a darker or
    --       black body background improves readability
    -- TODO: Show warning / error traces in a pop up window that fades out automatically
    -- TODO: Add support for searching / pairing / deleting lights
    -- TODO: Ability to select UI language on a per user basis
    --
    page <- liftIO . flip runReaderT ae . flip execStateT (Page [] []) $ do
        -- Navigation dropdown
        addTitleBarNavDropDown (map fst lightGroupsList)
        -- 'All Lights' tile
        addAllLightsTile
        -- 'Scenes' header tile
        addScenesTile userID window >>= \grpShown -> do
            -- Scene tiles
            forM_ scenes $ \(sceneName, scene) ->
                addSceneTile sceneName scene grpShown
            -- Imported scenes tile
            addImportedScenesTile grpShown
        -- Create tiles for all light groups
        forM_ lightGroupsList $ \(groupName, groupLightIDs) -> do
            -- Build group switch tile for current light group
            addGroupSwitchTile groupName (HS.toList groupLightIDs) userID window
            -- Is the current group visible?
            let grpShown = userData ^. udVisibleGroupNames . to (HS.member groupName)
            -- Lights in the group are hashed by ID, sort by name for display
            let sortedIDs = sortBy ( compare `Data.Function.on`
                                       (\k -> maybe "" _lgtName $ HM.lookup k lights)
                                   ) $ HS.toList groupLightIDs
            -- Create all light tiles for the current light group
            forM_ sortedIDs $ \lightID ->
                case HM.lookup lightID lights of
                    Nothing    -> return ()
                    Just light -> addLightTile light lightID grpShown
        -- 'Schedules' header tile
        addSchedulesTile (map fst scenes) userID window >>= \grpShown -> do
            -- Schedule tiles
            forM_ schedules $ \(scheduleName, schedule) ->
                addScheduleTile scheduleName schedule grpShown
        -- Add a server tile when we're running on ARM (Raspbery Pi or similar)
        -- TODO: Command line option to control visibility of the server tile
        when (isInfixOf "arm" $ map toLower SI.arch) $ addServerTile
    -- Execute all blaze HTML builders and get HTML code for the entire dynamic part of the
    -- page. We generate our HTML with blaze-html and insert it with a single FFI call
    -- instead of using threepenny's HTML combinators. The latter at least used to have some
    -- severe performance issues, see
    -- https://github.com/HeinrichApfelmus/threepenny-gui/issues/131
    --
    -- TODO: We're using String for everything here, inefficient
    --
    let tilesHtml = renderHtml . sequence_ . reverse $ page ^. pgTiles
    -- Insert generated HTML. Note that we use the string substitution feature of the
    -- ffi function to actually insert our generated HTML. This places all the HTML
    -- in double quotes at the point of insertion and \-escapes all quotes in the actual
    -- HTML. Also, if we did not do it this way and escaped the string ourselves, any
    -- %-sign in the HTML would trigger string substitution with ffi and the call would fail
    runFunction $ ffi "document.getElementById('lights').innerHTML = %1" tilesHtml
    finishPage <- liftIO getCurrentTime
    -- Now that we build the page, execute all the UI actions to register event handlers.
    -- Please see the comment for onElementID on why we batch it like this
    setCallBufferMode BufferRun
    sequence_ . reverse $ page ^. pgUIActions
    flushCallBuffer
    setCallBufferMode NoBuffering
    -- We're done building the page, hide spinner
    void $ getElementByIdSafe window "navbar-spinner" & set UI.src "static/svg/checkmark.svg"
    finishEvents <- liftIO getCurrentTime
    -- Duplicate broadcast channel
    tchan <- liftIO . atomically $ dupTChan _aeBroadcast
    -- Worker thread for receiving light updates
    --
    -- TODO: Worker thread creation and connected user count bookkeeping happens right
    --       here and then in the disconnect handler. This feels flimsy, I wish there was
    --       something as solid as a bracket pattern that would ensure no dangling threads
    --       and user counts are left hanging around, no matter where an exception occurs
    --
    updateWorker <- liftIO . async $ lightUpdateWorker window tchan
    -- Increment connected user count
    liftIO . atomically . modifyTVar' _aeConnectedUsers $ succ
    -- Disconnect handler, cancel light update worker and decrement user count
    on UI.disconnect window . const . liftIO $ do
        -- TODO: This is a potential resource leak, see
        --       https://github.com/HeinrichApfelmus/threepenny-gui/issues/133
        remainingUsers <- atomically $ do
            modifyTVar' _aeConnectedUsers pred
            readTVar _aeConnectedUsers
        traceS TLInfo $ "User ID '" <> fromCookieUserID userID <> "' disconnected ("
            <> show remainingUsers <> " users remaining)"
        cancel updateWorker
    -- Trace some performance measurements (TODO: Show page size in characters)
    traceS TLInfo
        ( printf "Page building: %.2fs / Event registration: %.2fs"
                 (realToFrac $ diffUTCTime finishPage   start      :: Double)
                 (realToFrac $ diffUTCTime finishEvents finishPage :: Double)
        )

-- Update DOM elements with light update messages received
--
-- TODO: We don't handle addition / removal of lights or changes in properties like the
--       name. Maybe refresh page automatically
--
-- TODO: Because getElementByIdSafe throws when we pass it a non-existent element, our
--       entire worker thread will just stop when we receive an update for a new light,
--       or one with a changed ID etc.
--
lightUpdateWorker :: Window -> LightUpdateTChan -> IO ()
lightUpdateWorker window tchan = runUI window $ loop
  where
    turnOnOff elementID onOff =
        -- We can't just set the opacity directly and use CSS 'transition', as this
        -- breaks the fade[In|Out]() methods we use when showing / hiding groups, use
        -- jQuery instead to do the animation of the opacity
        runFunction . ffi ("$('#" <> elementID <> "').animate({opacity: %1}, 400)") $
            if onOff then enabledOpacity else disabledOpacity
    loop = forever $
      (liftIO . atomically $ readTChan tchan) >>=
        \(lightID, update) -> case update of
          -- Light turned on / off
          LU_OnOff s -> turnOnOff (buildLightID lightID "tile") s
          -- All lights off, grey out 'All Lights' tile
          LU_LastOff -> turnOnOff (buildGroupID (GroupName "all-lights") "tile") False
          -- At least one light on, activate 'All Lights' tile
          LU_FirstOn -> turnOnOff (buildGroupID (GroupName "all-lights") "tile") True
          -- All lights in a group off, grey out group switch tile
          LU_GroupLastOff grp -> turnOnOff (buildGroupID grp "tile") False
          -- At least one light in a group on, activate group switch tile
          LU_GroupFirstOn grp -> turnOnOff (buildGroupID grp "tile") True
          -- Brightness change
          LU_Brightness brightness -> do
            let brightPercent = printf "%.0f%%" (fromIntegral brightness * 100 / 255 :: Float)
            getElementByIdSafe window (buildLightID lightID "brightness-bar") >>= \e ->
              void $ return e & set style [("width", brightPercent)]
            getElementByIdSafe window (buildLightID lightID "brightness-percentage") >>= \e ->
              void $ return e & set UI.text brightPercent
          -- Color change
          LU_Color col ->
            getElementByIdSafe window (buildLightID lightID "image") >>= \e ->
              void $ return e & set style [("background", col)]

