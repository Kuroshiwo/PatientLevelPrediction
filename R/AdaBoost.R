# @file AdaBoost.R
#
# Copyright 2020 Observational Health Data Sciences and Informatics
#
# This file is part of PatientLevelPrediction
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

#' Create setting for AdaBoost with python
#' @param nEstimators    The maximum number of estimators at which boosting is terminated
#' @param learningRate   Learning rate shrinks the contribution of each classifier by learningRate.
#'                       There is a trade-off between learningRate and nEstimators .
#' @param seed           A seed for the model
#'
#' @examples
#' \dontrun{
#' model.adaBoost <- setAdaBoost(size = 4, alpha = 1e-05, seed = NULL)
#' }
#' @export
setAdaBoost <- function(nEstimators = 50, learningRate = 1, seed = NULL) {

  if (!class(seed) %in% c("numeric", "NULL", "integer"))
    stop("Invalid seed")
  if (!class(nEstimators) %in% c("numeric", "integer"))
    stop("nEstimators must be a numeric value >0 ")
  if (min(nEstimators) < 1)
    stop("nEstimators must be greater that 0 or -1")
  if (!class(learningRate) %in% c("numeric", "integer"))
    stop("learningRate must be a numeric value >0 and <=1")
  if (max(learningRate) > 1)
    stop("learningRate must be less that or equal to 1")
  if (min(learningRate) < 0)
    stop("learningRate must be a numeric value >0")

  # test python is available and the required dependancies are there:
  ##checkPython()

  # set seed
  if(is.null(seed[1])){
    seed <- as.integer(sample(100000000,1))
  }
  
  result <- list(model = "fitAdaBoost",
                 param = split(expand.grid(nEstimators = nEstimators,
                                           learningRate = learningRate,
                                           seed = seed[1]), 1:(length(nEstimators) * length(learningRate))),
                 name = "AdaBoost")
  class(result) <- "modelSettings"

  return(result)
}

fitAdaBoost <- function(population,
                        plpData,
                        param,
                        search = "grid",
                        quiet = F,
                        outcomeId,
                        cohortId,
                        ...) {

  # check covariate data
  if (!FeatureExtraction::isCovariateData(plpData$covariateData))
    stop("Needs correct covariateData")

  if (colnames(population)[ncol(population)] != "indexes") {
    warning("indexes column not present as last column - setting all index to 1")
    population$indexes <- rep(1, nrow(population))
  }

  # connect to python if not connected
  ##initiatePython()

  start <- Sys.time()

  population$rowIdPython <- population$rowId - 1  # -1 to account for python/r index difference
  pPopulation <- as.matrix(population[,c('rowIdPython','outcomeCount','indexes')])
  
  # convert plpData in coo to python:
  x <- toSparseM(plpData, population, map = NULL)
  data <- reticulate::r_to_py(x$data)
  
  # save the model to outLoc TODO: make this an input or temp location?
  outLoc <- createTempModelLoc()
  # clear the existing model pickles
  for(file in dir(outLoc))
    file.remove(file.path(outLoc,file))

  # do cross validation to find hyperParameter
  hyperParamSel <- lapply(param, function(x) do.call(trainAdaBoost, listAppend(x, 
                                                                      list(train = TRUE, 
                                                                      population=pPopulation, 
                                                                      plpData=data,
                                                                      quiet=quiet))))
  
  
  cvAuc <- do.call(rbind, lapply(hyperParamSel, function(x) x$aucCV))
  colnames(cvAuc) <- paste0('fold_auc', 1:ncol(cvAuc))
  auc <- unlist(lapply(hyperParamSel, function(x) x$auc))
  
  cvPrediction <- lapply(hyperParamSel, function(x) x$prediction )
  cvPrediction <- cvPrediction[[which.max(auc)[1]]]
  
  hyperSummary <- cbind(do.call(rbind, param), cvAuc, auc= auc)

  writeLines('Training Final')
  # now train the final model and return coef
  bestInd <- which.max(abs(auc - 0.5))[1]
  finalModel <- do.call(trainAdaBoost, listAppend(param[[bestInd]], 
                                         list(train = FALSE, 
                                         modelLocation=outLoc, 
                                         population=pPopulation, 
                                         plpData=data,
                                         quiet=quiet)))

  # get the coefs and do a basic variable importance:
  varImp <- finalModel[[2]]
  varImp[is.na(varImp)] <- 0
  
  covariateRef <- as.data.frame(plpData$covariateData$covariateRef)
  incs <- rep(1, nrow(covariateRef))
  covariateRef$included <- incs
  covariateRef$covariateValue <- unlist(varImp)


  # select best model and remove the others (!!!NEED TO EDIT THIS)
  modelTrained <- file.path(outLoc)
  param.best <- param[[bestInd]]

  comp <- start - Sys.time()
  
  # train prediction
  pred <- finalModel[[1]]
  pred[,1] <- pred[,1] + 1 # converting from python to r index
  colnames(pred) <- c('rowId','outcomeCount','indexes', 'value')
  pred <- as.data.frame(pred)
  attr(pred, "metaData") <- list(predictionType="binary")
  prediction <- merge(population, pred[,c('rowId', 'value')], by='rowId')
  
  # return model location (!!!NEED TO ADD CV RESULTS HERE)
  result <- list(model = modelTrained,
                 trainCVAuc = list(value = unlist(cvAuc[bestInd,]),
                                   prediction = cvPrediction),#hyperParamSel,
                 hyperParamSearch = hyperSummary,
                 modelSettings = list(model = "fitAdaBoost", modelParameters = param.best),
                 metaData = plpData$metaData,
                 populationSettings = attr(population, "metaData"),
                 outcomeId = outcomeId,
                 cohortId = cohortId,
                 varImp = covariateRef,
                 trainingTime = comp,
                 dense = 0,
                 covariateMap = x$map,
                 predictionTrain=prediction)
  class(result) <- "plpModel"
  attr(result, "type") <- "pythonReticulate"
  attr(result, "predictionType") <- "binary"


  return(result)
}


trainAdaBoost <- function(population, plpData, nEstimators = 50, learningRate = 1, seed = NULL, train = TRUE, modelLocation=NULL, quiet=FALSE) {

  e <- environment()
  # then run standard python code
  reticulate::source_python(system.file(package='PatientLevelPrediction','python','adaBoostFunctions.py'), envir = e)

  result <- train_adaboost(population=population, 
                           plpData=plpData, 
                           train = train,
                           n_estimators = as.integer(nEstimators), 
                           learning_rate = learningRate, 
                           modelOutput = modelLocation,
                           seed = as.integer(seed), 
                           quiet = quiet)
  
  if (train) {
    # then get the prediction
    pred <- result
    colnames(pred) <- c("rowId", "outcomeCount", "indexes", "value")
    pred <- as.data.frame(pred)
    attr(pred, "metaData") <- list(predictionType = "binary")
    
    aucCV <- lapply(1:max(pred$indexes), function(i){computeAuc(pred[pred$indexes==i,])})

    auc <- computeAuc(pred)
    writeLines(paste0("CV model obtained CV AUC of ", auc))
    return(list(auc = auc, aucCV = aucCV, prediction = pred[pred$indexes>0,]))
  }

  return(result)
}
