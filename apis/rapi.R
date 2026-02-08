# apis/rapi.R
# PMxAgent R API Router - Modular architecture

#------------------------------------------------------------
#* @apiTitle       R API
#* @apiDescription Pharmacometric functions exposed via plumber
#------------------------------------------------------------

library(plumber)
library(ggplot2)
library(patchwork)
library(PKNCA)
library(mrgsolve)

# Source all utilities and models (available to all endpoints)
source("utils/constants.R")
source("utils/validation.R")
source("utils/units.R")
source("utils/pknca_units.R")
source("utils/colors.R")
source("utils/plotting.R")
source("models/mrgsolve_pk.R")
source("models/er_models.R")

# Initialize mrgsolve models at startup
initialize_pk_models()

# Helper function to copy routes from a sub-router to the main router
# This preserves the full endpoint specification including OpenAPI metadata
copy_routes <- function(main_pr, sub_pr) {
  # Get all endpoints from the sub-router
  endpoints <- sub_pr$endpoints
  for (path in names(endpoints)) {
    for (endpoint_list in endpoints[[path]]) {
      # Register the full endpoint object to preserve all metadata
      # including summary, description, and other OpenAPI annotations
      main_pr$handle(
        methods = endpoint_list$verbs,
        path = endpoint_list$path,
        handler = endpoint_list$getFunc(),
        serializer = endpoint_list$serializer,
        comments = endpoint_list$comments,
        params = endpoint_list$params,
        responses = endpoint_list$responses,
        tags = endpoint_list$tags
      )
    }
  }
  main_pr
}

#* @plumber
function(pr) {
  # Load endpoint routers (dependencies already loaded above)
  nca_router <- plumb("endpoints/nca.R")
  er_router <- plumb("endpoints/er.R")
  pk_router <- plumb("endpoints/pk.R")

  # Copy routes from each sub-router to main router
  # This preserves the original paths (/NCA, /ER, /PK) and OpenAPI metadata
  pr <- copy_routes(pr, nca_router)
  pr <- copy_routes(pr, er_router)
  pr <- copy_routes(pr, pk_router)

  pr
}
