module Main where

import Data.Either
import Data.List as DL
import Data.Text as T
import Graphics.Gloss
import Graphics.Gloss.Interface.IO.Game as Gl
import Graphics.Gloss.Juicy
import Protolude as P
import System.Directory
import System.Environment
import System.FilePath
import System.Process
import Graphics.HsExif


type Corner = Point

type CornersTup = (Corner, Corner, Corner, Corner)


-- | Projection map from corner to corner
type ProjMap =
  ( (Corner, Corner)
  , (Corner, Corner)
  , (Corner, Corner)
  , (Corner, Corner)
  )


-- | Not used at the moment
-- rotateProjMap :: Float -> ProjMap -> ProjMap
-- rotateProjMap rotation pMap@((f1,t1), (f2,t2), (f3,t3), (f4,t4)) =
--   case rotation of
--     -90 -> ((f1,t4), (f2,t1), (f3,t2), (f4,t3))
--     90  -> ((f1,t2), (f1,t3), (f1,t4), (f1,t1))
--     180 -> ((f1,t3), (f1,t4), (f1,t1), (f1,t2))
--     _   -> pMap


data ConversionMode
  = CallConversion
  | SpawnConversion


-- | State of app (list of corners is reversed to order of addition)
data AppState = AppState
  { corners :: [Corner]
  , image :: Picture

  , imgViewWidth :: Int
  , imgViewHeight :: Int

  , imgWidthOrig :: Int
  , imgHeightOrig :: Int

  , imgWidthTrgt :: Int
  , imgHeightTrgt :: Int

  , rotation :: Float

  , inputPath :: FilePath
  , outputPath :: FilePath
  , scaleFactor :: Float
  }
  deriving Show


initialState :: AppState
initialState = AppState
  { corners = []
  , image = Blank

  , imgViewWidth = 1280
  , imgViewHeight = 960

  , imgWidthOrig = 0
  , imgHeightOrig = 0

  , imgWidthTrgt = 0
  , imgHeightTrgt = 0

  , rotation = 0

  , inputPath = ""
  , outputPath = ""
  , scaleFactor = 1
  }


loadImage :: FilePath -> IO (Either Text (Picture, Map ExifTag ExifValue))
loadImage filePath = do
  picMaybe <- loadJuicy filePath

  let
    allowedExtensions =
      [ ".jpeg"
      , ".jpg"
      , ".png"
      , ".bmp"
      , ".gif"
      , ".hdr"
      ]
    fileExtension = takeExtension filePath

  case picMaybe of
    Nothing -> do
      if elem fileExtension allowedExtensions
      then pure $ Left "Error: Image couldn't be loaded"
      else pure $ Left $ "Error: File extension \""
                          <> T.pack fileExtension
                          <> "\" is not supported"

    Just picture -> do
      exifMapEither <- parseFileExif filePath

      case exifMapEither of
        Left _ -> pure $ Right (picture, mempty)
        Right exifMap -> pure $ Right (picture, exifMap)


calculateSizes :: AppState -> AppState
calculateSizes appState =
  let
    widthFrac = fromIntegral $ appState&imgWidthOrig
    heightFrac = fromIntegral $ appState&imgHeightOrig
    scaleFactorX = (fromIntegral $ appState&imgViewWidth) / widthFrac
    scaleFactorY = (fromIntegral $ appState&imgViewHeight) / heightFrac
    scaleFactor = min scaleFactorX scaleFactorY
    imgWidthTrgt = round $ scaleFactor * widthFrac
    imgHeightTrgt = round $ scaleFactor * heightFrac
  in
    appState
      { imgWidthTrgt
      , imgHeightTrgt
      , scaleFactor
      , corners = originTopLeft (-imgWidthTrgt) (imgHeightTrgt) $
          scalePoints (1 / scaleFactor) (getCorners appState)
      }


startApp :: FilePath -> FilePath -> Int -> Int -> Float -> Picture -> IO ()
startApp inPath outPath imgWdth imgHgt rota pic = do
  let
    initialX = 100
    initialY = 100
    ticksPerSecond = 10
    distance = 0.1

    stateWithSizes = calculateSizes $ initialState
      { imgWidthOrig = imgWdth
      , imgHeightOrig = imgHgt
      , rotation = rota
      , image = pic
      , inputPath = inPath
      , outputPath = outPath
      }

  let
    wdthFrac = fromIntegral $ stateWithSizes&imgWidthOrig
    hgtFrac = fromIntegral $ stateWithSizes&imgHeightOrig

    stateWithImage = stateWithSizes
      { corners = originTopLeft
          (-(stateWithSizes&imgWidthTrgt))
          (stateWithSizes&imgHeightTrgt) $
            scalePoints (1 / (stateWithSizes&scaleFactor)) $ P.reverse
              [ (wdthFrac * distance, hgtFrac * distance)
              , (wdthFrac * (1 - distance), hgtFrac * distance)
              , (wdthFrac * (1 - distance), hgtFrac * (1 - distance))
              , (wdthFrac * distance, hgtFrac * (1 - distance))
              ]
      }

    window = InWindow
      inPath
      (stateWithImage&imgViewWidth, stateWithImage&imgViewHeight)
      (initialX, initialY)

  putText "Starting the app …"

  playIO
    window
    black
    ticksPerSecond
    stateWithImage
    makePicture
    handleEvent
    stepWorld


stepWorld :: Float -> AppState -> IO AppState
stepWorld _ =
  pure . identity


-- | Render the app state to a picture.
makePicture :: AppState -> IO Picture
makePicture appState =
  let
    radius = 6
    thickness = 4
    drawCorner (x, y) =
      Translate x y (color green $ ThickCircle radius thickness)
    drawEdges points =
      color (makeColor 0.2 1 0.5 0.4) $ Polygon points
    -- drawButton buttonWidth buttonHeight =
    --   Translate
    --     (((fromIntegral $ appState&imgViewWidth) / 2.0)
    --       - ((fromIntegral $ buttonWidth) / 2.0))
    --     (((fromIntegral $ appState&imgViewHeight) / 2.0)
    --       - ((fromIntegral $ buttonHeight) * 1.5))
    --     $ color red $ rectangleSolid
    --       (fromIntegral $ buttonWidth)
    --       (fromIntegral $ buttonHeight)
  in
    pure $ Pictures $ (
      (Scale (appState&scaleFactor) (appState&scaleFactor) (appState&image)) :
      (drawEdges $ appState&corners ) :
      -- drawButton 200 100 :
      (fmap drawCorner $ appState&corners)
      )

replaceElemAtIndex :: Int -> a -> [a] -> [a]
replaceElemAtIndex theIndex newElem (x:xs) =
  if theIndex == 0
  then newElem : xs
  else x : replaceElemAtIndex (theIndex - 1) newElem xs
replaceElemAtIndex _ _ [] = []


calcDistance :: Point -> Point -> Float
calcDistance (x1 , y1) (x2 , y2) =
  let
    xDelta = x1 - x2
    yDelta = y1 - y2
  in
    sqrt (xDelta * xDelta + yDelta * yDelta)


-- | Get index of closest point
getIndexClosest :: [Point] -> Point -> Int
getIndexClosest points point =
  let
    distances = fmap (calcDistance point) points
    minDistance = DL.minimum distances
  in
    fromMaybe 0 (elemIndex minDistance distances)


addCorner :: AppState -> Corner -> AppState
addCorner appState newCorner =
  let
    theCorners = corners appState
    newCorners =
      if (P.length theCorners) < 4
      then newCorner : theCorners
      else replaceElemAtIndex
        (getIndexClosest theCorners newCorner)
        newCorner
        theCorners
  in
    appState {corners = newCorners}


-- TODO: Use correct algorithm as described in the readme
getTargetShape :: CornersTup -> (Float, Float)
getTargetShape (topLeft, topRight, btmRight, btmLeft) =
  let
    topEdgeLength    = calcDistance topLeft topRight
    bottomEdgeLength = calcDistance btmLeft btmRight
    width            = (topEdgeLength + bottomEdgeLength) / 2

    leftEdgeLength   = calcDistance topLeft btmLeft
    rightEdgeLength  = calcDistance topRight btmRight
    height           = (leftEdgeLength + rightEdgeLength) / 2
  in
    (width, height)


toQuadTuple :: [a] -> Either Text (a, a, a, a)
toQuadTuple [tl, tr, br, bl] = Right (tl, tr, br, bl)
toQuadTuple _                = Left "The list must contain 4 values"


-- | Assuming coordinate system starts top left
-- | 'getProjectionMap clickShape targetShape'
getProjectionMap :: CornersTup -> (Float, Float) -> ProjMap
getProjectionMap (tl, tr, br, bl) (wdth, hgt) =
  ( (tl, (0,    0))
  , (tr, (wdth, 0))
  , (br, (wdth, hgt))
  , (bl, (0,    hgt))
  )


-- | Accommodate ImageMagick's counter-clockwise direction
toCounterClock :: (a, a, a, a) -> (a, a, a, a)
toCounterClock (tl, tr, br, bl) = (tl, bl, br, tr)


-- | Fix weird gloss coordinate system
originTopLeft :: Int -> Int -> [Point] -> [Point]
originTopLeft width height = fmap
  (\(x, y) ->
    ( x + ((fromIntegral width) / 2.0)
    , - (y - ((fromIntegral height) / 2.0))
    )
  )


scalePoints :: Float -> [Point] -> [Point]
scalePoints scaleFac = fmap $
  \(x, y) -> (x / scaleFac, y / scaleFac)


getCorners :: AppState -> [Point]
getCorners appState =
  scalePoints (scaleFactor appState) $ originTopLeft
    (appState&imgWidthTrgt)
    (appState&imgHeightTrgt)
    (P.reverse $ corners appState)


handleEvent :: Event -> AppState -> IO AppState
handleEvent event appState =
  case event of
    EventKey (MouseButton LeftButton) Gl.Down _ point ->
      pure $ addCorner appState point

    EventKey (SpecialKey KeyEnter) Gl.Down _ _ -> do
      let
        cornersTrans = getCorners appState
        cornerTuple = fromRight
          ((0,0), (0,0), (0,0), (0,0))
          (toQuadTuple cornersTrans)
        targetShape = getTargetShape cornerTuple
        projectionMapNorm = toCounterClock $
          getProjectionMap cornerTuple targetShape

      putText $ "Target shape: " <> (show targetShape)
      putText $ "Marked corners: " <> (show cornerTuple)

      let
        convertArgs = getConvertArgs
          (inputPath appState)
          (outputPath appState)
          projectionMapNorm
          targetShape

      putText $ "Arguments for convert command:\n" <> (T.unlines convertArgs)

      correctAndWrite convertArgs

      exitSuccess

    EventKey (SpecialKey KeyEsc) Gl.Down _ _ -> do
      pure $ appState { corners = [] }

    EventResize (windowWidth, windowHeight) -> do
      pure $ calculateSizes $ appState
        { imgViewWidth = windowWidth
        , imgViewHeight = windowHeight
        }

    _ ->
      pure $ appState


-- FIXME: Don't rely on show implementation
showProjectionMap :: ProjMap -> Text
showProjectionMap pMap = pMap
  & show
  & T.replace "),(" " "
  & T.replace "(" ""
  & T.replace ")" ""


getConvertArgs :: FilePath -> FilePath -> ProjMap -> (Float, Float) -> [Text]
getConvertArgs inPath outPath projMap shape =
  traceShow (inPath, outPath, projMap, shape) [ (T.pack inPath)
  , "-auto-orient"
  , "-define", "distort:viewport="
      <> (show $ fst shape) <> "x" <> (show $ snd shape) <> "+0+0"

  -- TODO: Add flag to support this
  -- Use interpolated lookup instead of area resampling
  -- https://www.imagemagick.org/Usage/distorts/#area_vs_super
  -- , "-filter", "point"

  -- Prevent interpolation of unused pixels and avoid adding alpha channel
  , "-virtual-pixel", "black"

  -- TODO: Add flag to support switching
  -- , "-virtual-pixel", "Edge" -- default
  -- , "-virtual-pixel", "Dither"
  -- , "-virtual-pixel", "Random"
  -- TODO: Implement more sophisticated one upstream in Imagemagick

  , "-distort", "Perspective", showProjectionMap projMap
  , "+repage"
  , (T.pack outPath)
  ]


correctAndWrite :: [Text] -> IO ()
correctAndWrite args = do
  let
    conversionMode = CallConversion
    convertBin = "./imagemagick/bin/convert"

  currentDir <- getCurrentDirectory

  setEnv "MAGICK_HOME" (currentDir ++ "/imagemagick")
  setEnv "DYLD_LIBRARY_PATH" (currentDir ++ "/imagemagick/lib")

  -- TODO: Add CLI flag to switch between them
  case conversionMode of
    CallConversion -> do
      callProcess convertBin (fmap T.unpack args)
      putText $ "✅ Successfully saved converted image"

    SpawnConversion -> do
      _ <- spawnProcess convertBin (fmap T.unpack args)
      putText $ "✅ Successfully initiated conversion"

  pure ()


imgOrientToRot :: ImageOrientation -> Float
imgOrientToRot = \case
  Rotation MinusNinety            -> -90
  Normal                          -> 0
  Rotation Ninety                 -> 90
  Rotation HundredAndEighty       -> 180

  -- TODO: Also apply mirroring to image
  MirrorRotation MinusNinety      -> -90
  Mirror                          -> 0
  MirrorRotation Ninety           -> 90
  MirrorRotation HundredAndEighty -> 180


loadAndStart :: FilePath -> IO ()
loadAndStart filePath = do
  let outName = (takeBaseName filePath) <> "-fixed"

  pictureExifMapEither <- loadImage filePath

  case pictureExifMapEither of
    Left error -> putText error

    Right (picture@(Bitmap bitmapData), exifMap) -> do
      let
        imgOrient = fromMaybe Normal $ getOrientation exifMap
        rotation = imgOrientToRot imgOrient
        sizeTuple = bitmapSize bitmapData
        (imgWdth, imgHgt) = case rotation of
                              90  -> swap $ sizeTuple
                              -90 -> swap $ sizeTuple
                              _   -> sizeTuple

      putStrLn $ "Loaded file " <> filePath <> " " <> (show (imgWdth,imgHgt))
      putStrLn $ "with orientation " <> (show imgOrient :: Text)

      startApp
        filePath
        (replaceBaseName filePath outName)
        imgWdth
        imgHgt
        rotation
        (Rotate (-rotation) picture)

    Right _ -> putText $ "Error: Loaded file is not a Bitmap image. "
                      <> "This error should not be possible."


helpMessage :: Text
helpMessage =
  T.unlines [ "Usage: perspec <image> [image…]" ]


main :: IO ()
main = do
  args <- getArgs

  case args of
    [filePath] -> loadAndStart filePath
    _          -> putText helpMessage
