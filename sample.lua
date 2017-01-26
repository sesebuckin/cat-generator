require 'torch'
require 'image'
require 'paths'
require 'pl'
require 'layers.cudnnSpatialConvolutionUpsample'
require 'stn'
require 'LeakyReLU'
NN_UTILS = require 'utils.nn_utils'
DATASET = require 'dataset'

OPT = lapp[[
    --save          (default "logs")                          Directory in which the base 16x16 networks are stored.
    --G_base        (default "adversarial.net")               Filename for the 32x32 base network to load G from.
    --D_base        (default "adversarial.net")               Filename for the 32x32 base network to load D from.
    --neighbours                                              Whether to search for nearest neighbours of generated images in the dataset (takes long)
    --scale         (default 32)                              Height of images in the base network.
    --colorSpace    (default "rgb")                           rgb|yuv|hsl|y
    --writeto       (default "samples")                       Directory to save the images to
    --seed          (default 1)                               Random number seed to use.
    --gpu           (default 0)                               GPU to run on
    --runs          (default 1)                               How often to sample and save images
    --noiseDim      (default 100)                             Noise vector size.
    --batchSize     (default 16)                              Sizes of batches.
    --aws                                                     Run in AWS mode.
]]

if OPT.gpu < 0 then
    print("[ERROR] Sample script currently only runs on GPU, set --gpu=x where x is between 0 and 3.")
    exit()
end

if OPT.colorSpace == "y" then
    OPT.grayscale = true
end

-- Start GPU mode
print("Starting gpu support...")
require 'cutorch'
require 'cunn'
torch.setdefaulttensortype('torch.FloatTensor')
cutorch.setDevice(OPT.gpu + 1)

-- initialize seeds
math.randomseed(OPT.seed)
torch.manualSeed(OPT.seed)
cutorch.manualSeed(OPT.seed)

-- Image dimensions
if OPT.grayscale then
    IMG_DIMENSIONS = {1, OPT.scale, OPT.scale}
else
    IMG_DIMENSIONS = {3, OPT.scale, OPT.scale}
end

-- Initialize dataset
--DATASET.nbChannels = IMG_DIMENSIONS[1]
DATASET.colorSpace = OPT.colorSpace
DATASET.setFileExtension("jpg")
DATASET.setHeight(OPT.scale)
DATASET.setWidth(OPT.scale)

if OPT.aws then
    DATASET.setDirs({"/mnt/datasets/out_aug_64x64"})
else
    DATASET.setDirs({"dataset/out_aug_64x64"})
end

-- Main function that runs the sampling
function main()
    -- Load all models
    local G, D = loadModels()

    -- We need these global variables for some methods. Ugly code.
    MODEL_G = G
    MODEL_D = D

    print("Sampling...")
    for run=1,OPT.runs do
        -- save 64 randomly selected images from the training set
        local imagesTrainList = DATASET.loadRandomImages(64)
        -- dont use nn_utils.toImageTensor here, because the metatable of imagesTrainList was changed
        local imagesTrain = torch.Tensor(#imagesTrainList, imagesTrainList[1]:size(1), imagesTrainList[1]:size(2), imagesTrainList[1]:size(3)):float()
        for i=1,#imagesTrainList do
            imagesTrain[i] = imagesTrainList[i]
        end
        image.save(paths.concat(OPT.writeto, string.format('trainset_s1_%04d_base.jpg', run)), toGrid(imagesTrain, 8))

        -- sample 1024 new images from G
        local images = NN_UTILS.createImages(1024, false)

        -- validate image dimensions
        if images[1]:size(1) ~= IMG_DIMENSIONS[1] or images[1]:size(2) ~= IMG_DIMENSIONS[2] or images[1]:size(3) ~= IMG_DIMENSIONS[3] then
            print("[WARNING] dimension mismatch between images generated by base G and command line parameters, --grayscale falsly on/off or --scale not set correctly")
            print("Dimension G:", images[1]:size())
            print("Settings:", IMG_DIMENSIONS)
        end

        -- save big images of those 1024 random images
        image.save(paths.concat(OPT.writeto, string.format('random256_%04d_base.jpg', run)), toGrid(selectRandomImagesFrom(images, 256), 16))
        image.save(paths.concat(OPT.writeto, string.format('random1024_%04d_base.jpg', run)), toGrid(images, 32))

        -- Collect the best and worst images (according to D) from these images
        -- Save: 32 best images, 32 worst images, 32 randomly selected images
        local imagesBest, predictions = NN_UTILS.sortImagesByPrediction(images, false, 64)
        local imagesWorst, predictions = NN_UTILS.sortImagesByPrediction(images, true, 64)
        local imagesRandom = selectRandomImagesFrom(images, 64)
        imagesBest = NN_UTILS.toImageTensor(imagesBest)
        imagesWorst = NN_UTILS.toImageTensor(imagesWorst)
        imagesRandom = NN_UTILS.toImageTensor(imagesRandom)
        image.save(paths.concat(OPT.writeto, string.format('best_%04d_base.jpg', run)), toGrid(imagesBest, 8))
        image.save(paths.concat(OPT.writeto, string.format('worst_%04d_base.jpg', run)), toGrid(imagesWorst, 8))
        image.save(paths.concat(OPT.writeto, string.format('random_%04d_base.jpg', run)), toGrid(imagesRandom, 8))

        -- Extract the 16 best images and find their closest neighbour in the training set
        if OPT.neighbours then
            local searchFor = {}
            for i=1,16 do
                table.insert(searchFor, imagesBest[i]:clone())
            end
            local neighbours = findClosestNeighboursOf(searchFor)
            image.save(paths.concat(OPT.writeto, string.format('best_%04d_neighbours_base.jpg', run)), toNeighboursGrid(neighbours, 8))
        end

        xlua.progress(run, OPT.runs)
    end

    print("Finished.")
end

-- Searches for the closest neighbours (2-Norm/torch.dist) for each image in the given list.
-- @param images List of image tensors.
-- @returns List of tables {image, closest neighbour's image, distance}
function findClosestNeighboursOf(images)
    local result = {}
    local trainingSet = DATASET.loadImages(0, 9999999)
    for i=1,#images do
        local img = images[i]
        local closestDist = nil
        local closestImg = nil
        for j=1,trainingSet:size() do
            local dist = torch.dist(trainingSet[j], img)
            if closestDist == nil or dist < closestDist then
                closestDist = dist
                closestImg = trainingSet[j]:clone()
            end
        end
        table.insert(result, {img, closestImg, closestDist})
    end

    return result
end

-- Normalizes a tensor of images.
-- Currently that projects an images from 0.0 to 1.0 to range -1.0 to +1.0.
-- @param images Tensor of images
-- @param mean_ Currently ignored.
-- @param std_ Currently ignored.
-- @returns images Normalized images (NOTE: images are normalized in-place)
function normalize(images, mean_, std_)
    -- normalizes in-place
    NN_UTILS.normalize(images, mean_, std_)
    return images
end

-- Converts images to one image grid with set amount of rows.
-- @param images Tensor of images
-- @param nrow Number of rows.
-- @return Tensor
function toGrid(images, nrow)
    return image.toDisplayTensor{input=NN_UTILS.toRgb(images, OPT.colorSpace), nrow=nrow}
end

-- Converts a table of images as returned by findClosestNeighboursOf() to one image grid.
-- @param imagesWithNeighbours Table of (image, neighbour image, distance)
-- @returns Tensor
function toNeighboursGrid(imagesWithNeighbours)
    local img = imagesWithNeighbours[1][1]
    local imgpairs = torch.Tensor(#imagesWithNeighbours*2, img:size(1), img:size(2), img:size(3)):float()

    local imgpairs_idx = 1
    for i=1,#imagesWithNeighbours do
        imgpairs[imgpairs_idx] = imagesWithNeighbours[i][1]
        imgpairs[imgpairs_idx + 1] = imagesWithNeighbours[i][2]
        imgpairs_idx = imgpairs_idx + 2
    end

    return image.toDisplayTensor{input=NN_UTILS.toRgb(imgpairs, OPT.colorSpace), nrow=#imagesWithNeighbours}
end

-- Selects N random images from a tensor of images.
-- @param tensor Tensor of images
-- @param n Number of random images to select
-- @returns List/table of images
function selectRandomImagesFrom(tensor, n)
    local shuffle = torch.randperm(tensor:size(1))
    local result = {}
    for i=1,math.min(n, tensor:size(1)) do
        table.insert(result, tensor[ shuffle[i] ])
    end
    return result
end

-- Loads all necessary models/networks and returns them.
-- @returns G, D
function loadModels()
    local file

    -- load G base
    file = torch.load(paths.concat(OPT.save, OPT.G_base))
    local G = file.G
    G:evaluate()

    -- load D base
    file = torch.load(paths.concat(OPT.save, OPT.D_base))
    local D = file.D
    D:evaluate()

    return G, D
end

main()
