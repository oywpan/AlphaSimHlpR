#' popImprov1Cyc function
#'
#' Function to improve a simulated breeding population by one cycle. This version takes phenotyped individuals and crosses them to create new F1
#'
#' @param records The breeding program \code{records} object. See \code{fillPipeline} for details
#' @param bsp A list of breeding scheme parameters
#' @param SP The AlphaSimR SimParam object
#' @return A records object with a new F1 Pop-class object of progeny coming out of a population improvement scheme
#' 
#' @details This function uses penotypic records coming out of the product pipeline to choose individuals as parents to initiate the next breeding cycle
#' 
#' @examples
#' bsp <- specifyPipeline()
#' bsp <- specifyPopulation(bsp)
#' initList <- initializeFunc(bsp)
#' SP <- initList$SP
#' bsp <- initList$bsp
#' records <- initList$records
#' records <- productPipeline(records, bsp, SP)
#' records <- popImprov1(records, bsp, SP)
#' 
#' @export
popImprov1Cyc <- function(records, bsp, SP){
  # Include current year phenotypes for model training?
  trainRec <- records
  if (!bsp$useCurrentPhenoTrain){
    for (stage in 1+1:bsp$nStages){
      trainRec[[stage]] <- trainRec[[stage]][-length(trainRec[[stage]])]
    }
  }
  # Select parents among all individuals
  candidates <- records$F1@id
  crit <- bsp$selCritPopImprov(trainRec, candidates, bsp, SP)
  if (bsp$useOptContrib){
    progeny <- optContrib(records, bsp, SP, crit)
  } else{
    parents <- records$F1[candidates[order(crit, decreasing=T)[1:bsp$nParents]]]
    progeny <- randCross(parents, nCrosses=bsp$nCrosses, nProgeny=bsp$nProgeny, ignoreGender=T, simParam=SP)
  }
  progeny@fixEff <- rep(as.integer(max(records$stageOutputs$year) + 1), bsp$nSeeds)
  parentsUsed <- unique(c(progeny@mother, progeny@father))
  stgCyc <- sapply(parentsUsed, whereIsID, records=records)
  stgCyc <- table(stgCyc[1,], stgCyc[2,])
  strtStgOut <- nrow(records$stageOutputs) - bsp$nStages - 1
  for (i in 1:nrow(stgCyc)){
    stage <- as.integer(rownames(stgCyc)[i])
    records$stageOutputs$nContribToPar[[strtStgOut + stage]] <- tibble(cycle=as.integer(colnames(stgCyc)), nContribToPar=stgCyc[i,])
  }
  records$F1 <- c(records$F1, progeny)
  return(records)
}

#' whereIsID function
#'
#' Function to figure out where an ID is in the records
#'
#' @param id String id use in AlphaSimR
#' @param records The breeding program \code{records} object. See \code{fillPipeline} for details
#' @return Integer vector with the stage and cycle where the id was found or c(NA, NA)
#' 
#' @details Goes through the records to find the last time id was phenotyped
#' 
#' @examples
#' stgCyc <- whereIsID(id, records)
#' 
whereIsID <- function(id, records){
  found <- FALSE
  stage <- length(records)
  while (stage > 2 & !found){
    stage <- stage - 1
    for (cycle in length(records[[stage]]):1){
      found <- id %in% records[[stage]][[cycle]]$id
      if (found) break
    }
  }
  if (!found){
    if (id %in% records[[1]]@id){
      stage <- 1; cycle <- 1
    } else{
      stage <- NA; cycle <- NA
    }
  }
  return(c(stage=stage, cycle=cycle))
}

#' popImprov2Cyc function
#'
#' Function to improve a simulated breeding population by one cycle. This version does two cycles of predicting F1 individuals and making new F1s
#'
#' @param records The breeding program \code{records} object. See \code{fillPipeline} for details
#' @param bsp List of breeding scheme parameters
#' @param SP The AlphaSimR SimParam object
#' @return A records object with the F1 Pop-class object updated with new progeny coming out of a population improvement scheme
#' 
#' @details This function uses penotypic records coming out of the product pipeline to choose individuals as parents to initiate the next breeding cycle
#' 
#' @examples
#' bsp <- specifyPipeline()
#' bsp <- specifyPopulation(bsp)
#' initList <- initializeFunc(bsp)
#' SP <- initList$SP
#' bsp <- initList$bsp
#' records <- initList$records
#' records <- prodPipeSimp(records, bsp, SP)
#' records <- popImprov2Cyc(records, bsp, SP)
#' 
#' @export
popImprov2Cyc <- function(records, bsp, SP){
  # Don't include current year (if specified) for the first cycle
  # but do include it for the second cycle
  useCurrentPhenoTrain <- bsp$useCurrentPhenoTrain
  for (cycle in 1:2){
    trainRec <- records
    if (!useCurrentPhenoTrain){
      for (stage in 1+1:bsp$nStages){
        trainRec[[stage]] <- trainRec[[stage]][-length(trainRec[[stage]])]
      }
    }
    candidates <- records$F1@id
    crit <- bsp$selCritPopImprov(trainRec, candidates, bsp, SP)
    parents <- records$F1[candidates[order(crit, decreasing=T)[1:bsp$nParents]]]
    progeny <- randCross(parents, nCrosses=bsp$nCrosses, nProgeny=bsp$nProgeny, ignoreGender=T, simParam=SP)
    records$F1 <- c(records$F1, progeny)
    useCurrentPhenoTrain <- TRUE
  }
  return(records)
}

#' optContrib function
#'
#' function uses optiSel to identify number of progeny, allocate mates to minimize inbreeding depression, and return progeny
#' NOTE: This function assumes that all selection candidates have been genotyped
#' If stageToGenotype has been set to a later stage, that might not be true
#'
#' @param records The breeding program \code{records} object. See \code{fillPipeline} for details
#' @param bsp A list of product pipeline parameters
#' @param SP The AlphaSimR SimParam object (needed to pull SNPs)
#' @param crit Named vector of selection criterion to be maximized
#' @return Pop class object with the progeny from optimum contribution crosses
#' @details Calculate a grm of individuals with high enough crit, then maximize crit subject to a target increase of relatedness consistent with bsp$targetEffPopSize
#' @examples 
#' crit <- bv(records$F1); names(crit) <- records$F1@id
#' progeny <- optContrib(records, bsp, SP, crit)
#' @export
optContrib <- function(records, bsp, SP, crit){
  require(optiSel)
  candidates <- names(crit)[order(crit, decreasing=T)[1:bsp$nCandOptCont]]
  grm <- sommer::A.mat(pullSnpGeno(records$F1[candidates], simParam=SP) - 1)
  grm <- grm[candidates, candidates] # Put it in the right order
  phen <- data.frame(Indiv=candidates, crit=crit[candidates])
  invisible(capture.output(cand <- optiSel::candes(phen, grm=grm, quiet=T)))

  Ne <- bsp$targetEffPopSize
  con <- list(
    ub.grm = 1-(1-cand$mean$grm)*(1-1/(2*Ne))
  )
  oc <- opticont("max.crit", cand, con, quiet=T, trace=F)$parent[, c("Indiv", "oc")]
  keep <- oc$oc > 1 / bsp$nSeeds / 4
  oc <- oc[keep,]
  grm <- grm[keep, keep]
  oc$nOffspr <- oc$oc * 2 * bsp$nSeeds
  # Make sum to 2*bsp$nSeeds: very arcane but it works
  curOffspr <- sum(round(oc$nOffspr))
  if (curOffspr != 2*bsp$nSeeds){
    nDiff <- 2*bsp$nSeeds - curOffspr
    addOrSub <- sign(nDiff)
    decim <- addOrSub * (oc$nOffspr - floor(oc$nOffspr))
    keep <- decim + (addOrSub < 0) < 0.5
    chng <- oc$Indiv[keep]; decim <- decim[keep]
    chng <- chng[order(decim, decreasing=T)[1:abs(nDiff)]]
    oc$nOffspr[oc$Indiv %in% chng] <- oc$nOffspr[oc$Indiv %in% chng] + addOrSub
  }
  oc$nOffspr <- round(oc$nOffspr)
  oc$remOffspr <- oc$nOffspr
  crossPlan <- NULL
  for (curPar in order(oc$nOffspr, decreasing=T)){
    while(oc$remOffspr[curPar] > 0){
      # find which other has minimum relationship with curPar
      mate <- which.min(grm[curPar,])
      if (mate == curPar){ # Happens if last parent somewhat related to all
        redis <- sample(nrow(crossPlan), ceiling(oc$remOffspr[mate]/2))
        redisPar <- c(crossPlan[redis,])
        crossPlan <- rbind(crossPlan[-redis,], cbind(oc$Indiv[mate], redisPar))
        oc$remOffspr[curPar] <- 0
      } else{
        nProg <- min(oc$remOffspr[curPar], oc$remOffspr[mate], bsp$nProgeny)
        if (nProg > 0){
          crossPlan <- rbind(crossPlan, matrix(rep(c(oc$Indiv[curPar], oc$Indiv[mate]), each=nProg), nrow=nProg))
          oc$remOffspr[curPar] <- oc$remOffspr[curPar] - nProg
          oc$remOffspr[mate] <- oc$remOffspr[mate] - nProg
        }
        grm[curPar, mate] <- grm[mate, curPar] <- 1e6
      }
    }
  }
  if (nrow(crossPlan) > bsp$nSeeds){
    remRow <- sample(nrow(crossPlan), nrow(crossPlan) - bsp$nSeeds)
    crossPlan <- crossPlan[-remRow,]
  }
  if (nrow(crossPlan) < bsp$nSeeds){
    addRow <- sample(nrow(crossPlan), bsp$nSeeds - nrow(crossPlan))
    crossPlan <- rbind(crossPlan, crossPlan[addRow,])
  }
  progeny <- makeCross(records[[1]], crossPlan, simParam=SP)
  return(progeny)
}
