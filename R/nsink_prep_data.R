#' Prepares N-Sink data for a given HUC
#'
#' In addition to having local access to the required dataset, those datasets
#' need to have some preparation.  This function standardizes projections and
#' extents and clips all datasets to the boundary of the specified HUC.
#' Additionally, any tabular datasets (e.g. flow, time of travel, etc.) are
#' included in the output as well.
#'
#' @param huc A character string of the HUC12 ID.  Use
#'            \code{\link{nsink_get_huc_id}} to look up ID by name.
#' @param projection CRS to use, passed as ethier EPSG code (as numeric)
#'                   or WKT (as character).
#'                   This must be a projected CRS and not geographic as many of
#'                   the measurements required for the nsink analysis require
#'                   reliable length and area measurments.
#' @param data_dir Base directory that contains N-Sink data folders.  Data may
#'                 be downloaded with the \code{\link{nsink_get_data}} function.
#' @param year The year of the nlcd and impervious data that was retrieved with
#'             FedData's, \code{\link{get_nlcd}} function.
#' @return returns a list of sf, raster, or tabular objects for each of the
#'         required datasets plus the huc.
#' @importFrom methods as
#' @importFrom rlang .data
#' @export
#' @import sf
#' @examples
#' \dontrun{
#' library(nsink)
#' aea <- 5072
#' niantic_huc <- nsink_get_huc_id("Niantic River")$huc_12
#' niantic_nsink_data <- nsink_prep_data(huc = niantic_huc, projection = aea,
#' data_dir = "nsink_data")
#' # Example using EPSG code for projection
#' epsg <- 3748L
#' niantic_nsink_data <- nsink_prep_data(huc = niantic_huc, projection = epsg,
#'                 data_dir = "nsink_data")
#' }
nsink_prep_data <- function(huc, projection,
                            data_dir = normalizePath("nsink_data/",
                                                     winslash = "/",
                                                     mustWork = FALSE),
                            year = "2016") {
  year <- as.character(year)
  # Get vpu
  rpu <- unique(wbd_lookup[grepl(paste0("^", huc), wbd_lookup$HUC_12),]$RPU)

  #if(length(rpu) > 1){stop("More than 1 rpu selected.  This is not yet supported")}
  rpu <- rpu[!is.na(rpu)]

  #Add RPU to data_dir
  data_dir_orig <- data_dir
  for(i in seq_along(rpu)){
    data_dir <- data_dir_orig
    while(grepl(rpu[i], basename(data_dir))){
      data_dir <- dirname(data_dir)
      message("Do not include the RPU in the data directory.")
    }
    data_dir <- paste(data_dir, rpu[i], sep = "/")

    # Check for/create/clean data directory
    data_dir <- nsink_fix_data_directory(data_dir)

    # Check for/create/clean data directory
    message("Preparing data for nsink analysis...")
    dirs <- list.dirs(data_dir, full.names = FALSE, recursive = FALSE)

    if (all(c("attr", "erom", "fdr", "imperv", "nhd", "ssurgo", "wbd", "nlcd") %in% dirs)) {
      huc_sf_file <- list.files(paste0(data_dir, "wbd"), "WBD_Subwatershed.shp", full.names = TRUE,
                                recursive = TRUE)
      huc_sf <- st_read(huc_sf_file,quiet = TRUE)
      huc_sf <- huc_sf[grepl(paste0("^", huc), huc_sf$HUC_12), ]
      huc_sf <- mutate(huc_sf, selected_huc = huc)
      huc_sf <- group_by(huc_sf, .data$selected_huc)
      huc_sf <- summarize(huc_sf, selected_huc = unique(.data$selected_huc))
      huc_sf <- ungroup(huc_sf)
      huc_sf <- st_transform(huc_sf, crs = projection)
      # Use SSURGO to pull out salt water ssurgo poly's
      huc_sf <- suppressMessages(nsink_remove_openwater(huc_sf, data_dir))
      res <- units::set_units(30, "m")
      res <- units::set_units(res, st_crs(huc_sf, parameters = TRUE)$ud_unit,
                              mode = "standard")

      huc_raster <- terra::rast(huc_sf,resolution = as.numeric(res), crs = st_crs(huc_sf)$wkt)
      assign(paste0("rpu_",rpu[i]), list(
        streams = nsink_prep_streams(huc_sf, data_dir),
        lakes = nsink_prep_lakes(huc_sf, data_dir),
        fdr = nsink_prep_fdr(huc_sf, huc_raster, data_dir),
        impervious = nsink_prep_impervious(huc_sf, huc_raster, data_dir, year),
        nlcd = nsink_prep_nlcd(huc_sf, huc_raster, data_dir, year),
        ssurgo = nsink_prep_ssurgo(huc_sf, data_dir),
        q = nsink_prep_q(data_dir),
        tot = nsink_prep_tot(data_dir),
        lakemorpho = nsink_prep_lakemorpho(data_dir),
        huc = huc_sf,
        raster_template = huc_raster
      ))
    } else {
      stop(paste0(
        "The required data does not appear to be available in ",
        data_dir, ". Run nsink_get_data()."
      ))
    }
  }

  rpus <- ls(pattern = "rpu_")
  if(length(rpus)==1){
    get(rpus[1])
  } else if(length(rpus) == 2) {
    huc <- rbind(get(rpus[1])$huc, get(rpus[2])$huc)
    st_agr(huc) <- "constant"
    huc <- st_cast(huc, "MULTIPOLYGON")
    huc_raster <- terra::rast(huc, resolution = as.numeric(res),
                                 crs = terra::crs(huc))
    list(
      streams = rbind(get(rpus[1])$streams, get(rpus[2])$streams),
      lakes = rbind(get(rpus[1])$lakes, get(rpus[2])$lakes),
      fdr = suppressWarnings(terra::mosaic(
        terra::project(get(rpus[1])$fdr, huc_raster, method = "near"),
        terra::project(get(rpus[2])$fdr, huc_raster, method = "near"),
        fun = max)),
      impervious = suppressWarnings(terra::mosaic(
        terra::project(get(rpus[1])$impervious, huc_raster,
                              method = "near"),
        terra::project(get(rpus[2])$impervious, huc_raster,
                              method = "near"), fun = max)),
      nlcd = suppressWarnings(terra::mosaic(
        terra::project(get(rpus[1])$nlcd, huc_raster, method = "near"),
        terra::project(get(rpus[2])$nlcd, huc_raster, method = "near"),
        fun = max)),
      ssurgo = rbind(get(rpus[1])$ssurgo, get(rpus[2])$ssurgo),
      q = rbind(get(rpus[1])$q, get(rpus[2])$q),
      tot = rbind(get(rpus[1])$tot, get(rpus[2])$tot),
      lakemorpho = rbind(get(rpus[1])$lakemorpho, get(rpus[2])$lakemorpho),
      huc = huc,
      raster_template = huc_raster)
  }
}

#' Prepare streams data for N-Sink
#'
#' Standardizes streams data by transforming data, clipping to HUC, ...
#'
#' @param huc_sf An sf object of the Watershed Boundaries Dataset HUC12
#' @param data_dir Base directory that contains N-Sink data folders.  Data may
#'                 be downloaded with the \code{\link{nsink_get_data}} function.
#' @return returns an sf object of the NHDPlus streams for the huc_sf
#' @import dplyr sf
#' @importFrom rlang .data
#' @keywords  internal
nsink_prep_streams <- function(huc_sf, data_dir) {
  nhd_streams_file <- list.files(paste0(data_dir, "nhd"), "NHDFlowline.shp",
                         recursive = TRUE, full.names = TRUE)
  nhd_streams_file <- nhd_streams_file[!grepl(".xml", nhd_streams_file )]
  if (length(nhd_streams_file) == 1) {
    message("Preparing streams...")
    streams <- st_read(nhd_streams_file, quiet = TRUE)
    streams <- st_transform(streams, st_crs(huc_sf))
    streams <- st_zm(streams)
    streams <- rename_all(streams, tolower)
    streams <- rename(streams,
      stream_comid = "comid",
      lake_comid = "wbareacomi"
    )


    # Remove coastline
    streams <- filter(streams, .data$ftype != "Coastline")
    streams <- mutate(streams,
                      percent_length =
                        units::set_units(st_length(.data$geometry), "km")/
                        units::set_units(.data$lengthkm, "km"))
    streams <- streams[unlist(st_intersects(huc_sf, streams)),]
    streams <- filter(streams, .data$percent_length >= units::as_units(0.75))
    streams <- select(streams, -"lengthkm", -"shape_leng", -"percent_length")
    #HERE HERE HERE HERE
    st_agr(streams) <- "constant"
    streams <- st_crop(streams, st_bbox(huc_sf))
    streams <- mutate_if(streams, is.factor, as.character())

  } else {
    stop("The required data file does not exist.  Run nsink_get_data().")
  }

  streams
}

#' Prepare lakes data for N-Sink
#'
#' Standardizes lakes data by transforming data, clipping to HUC, and
#' renaming columns.
#'
#' @param huc_sf An sf object of the Watershed Boundaries Dataset HUC12
#' @param data_dir Base directory that contains N-Sink data folders.  Data may be
#'                 downloaded with the \code{\link{nsink_get_data}} function.
#' @return An sf object of the NHDPlus lakes for the huc_sf
#' @import dplyr sf
#' @importFrom rlang .data
#' @keywords  internal
nsink_prep_lakes <- function(huc_sf, data_dir) {
  nhd_waterbody_file <- list.files(paste0(data_dir, "nhd"), "NHDWaterbody.shp",
                                 recursive = TRUE, full.names = TRUE)
  nhd_waterbody_file <- nhd_waterbody_file[!grepl(".xml", nhd_waterbody_file )]
  if (length(nhd_waterbody_file) == 1) {
    message("Preparing lakes...")

    lakes <- st_read(nhd_waterbody_file, quiet = TRUE)
    lakes <- st_zm(lakes)
    lakes <- st_transform(lakes, st_crs(huc_sf))
    lakes <- rename_all(lakes, tolower)
    lakes <- rename(lakes, lake_comid = "comid")
    lakes <- filter(lakes, .data$ftype == "LakePond")
    lakes <- slice(lakes, unlist(st_intersects(huc_sf, lakes)))
  } else {
    stop("The required data file does not exist.  Run nsink_get_data().")
  }
  lakes
}

#' Prepare flow direction data for N-Sink
#'
#' Standardizes flow direction data by transforming data, and clipping to HUC.
#'
#' @param huc_sf An sf object of the Watershed Boundaries Dataset HUC12
#' @param huc_raster A raster object of the Watershed Boundaries Dataset HUC12
#' @param data_dir Base directory that contains N-Sink data folders.  Data may be
#'                 downloaded with the \code{\link{nsink_get_data}} function.
#' @return A raster object of the flow direction for the huc_sf but in
#'         the original fdr projection
#' @importFrom methods as
#' @keywords  internal
nsink_prep_fdr <- function(huc_sf, huc_raster, data_dir) {

  fdr_dir <- list.dirs(paste0(data_dir, "fdr"), full.names = TRUE,
                       recursive = FALSE)
  fdr_file <- list.dirs(fdr_dir, recursive = TRUE,
                        full.names = TRUE)
  fdr_file <- fdr_file[grepl("fdr", basename(fdr_file))]

  if (length(fdr_file) == 1) {
    message("Preparing flow direction...")

    fdr <- terra::rast(fdr_file)
    # reading ArcInfo GRID (AIG) sources with terra then unwrap/wrap screws this up
    # writing to tif then re-reading is a gross hack that works...
    suppressWarnings({terra::writeRaster(fdr, paste0(dirname(fdr_file), "fdr.tif"),
                       overwrite=TRUE)})
    fdr <- terra::rast(paste0(dirname(fdr_file), "fdr.tif"))
    huc_sf <- st_transform(huc_sf, st_crs(fdr))
    fdr <- terra::crop(fdr, huc_sf)
    fdr <- terra::mask(fdr, huc_sf)

  } else {
    stop("The required data file does not exist.  Run nsink_get_data().")
  }
  fdr
}

#' Prepare impervious cover data for N-Sink
#'
#' Standardizes impervious data by projecting to the coorect CRS,
#' and standardizing file name.
#'
#' @param huc_sf An sf object of the Watershed Boundaries Dataset HUC12
#' @param huc_raster A raster object of the Watershed Boundaries Dataset HUC12
#' @param data_dir Base directory that contains N-Sink data folders.  Data may
#'                 be downloaded with the \code{\link{nsink_get_data}} function.
#' @param year The year of the nlcd and impervious data that was retrieved with
#'             FedData's, \code{\link{get_nlcd}} function.
#' @return A raster object of the impervious cover for the huc_sf
#' @keywords  internal
nsink_prep_impervious <- function(huc_sf, huc_raster, data_dir, year) {

  huc12 <- unique(as.character(huc_sf$selected_huc))
  file <- list.files(paste0(data_dir, "imperv/"), pattern = ".tif")
  if (any(grepl(paste0("^", huc12, ".*", year, ".*\\.tif$"), file))){
    message("Preparing impervious...")

    if(length(file)>1){

      file <- file[grepl(paste0("^", huc12, "_.*", year, ".*\\.tif$"),file)]
    }

    impervious <- terra::rast(paste0(data_dir, "imperv/", file))
    impervious <- terra::project(impervious, huc_raster)
  } else {
    stop("The required data file does not exist.  Run nsink_get_data().")
  }
  impervious
}

#' Prepare NLCD data for N-Sink
#'
#' Standardizes NLCD data by by projecting to the coorect CRS,
#' and standardizing file name.
#'
#' @param huc_sf An sf object of the Watershed Boundaries Dataset HUC12
#' @param huc_raster A raster object of the Watershed Boundaries Dataset HUC12
#' @param data_dir Base directory that contains N-Sink data folders.  Data may
#'                 be downloaded with the \code{\link{nsink_get_data}} function.
#' @param year The year of the nlcd and impervious data that was retrieved with
#'             FedData's, \code{\link{get_nlcd}} function.
#' @return A raster object of the NLCD for the huc_sf
#' @keywords  internal
nsink_prep_nlcd <- function(huc_sf, huc_raster, data_dir, year) {
  huc12 <- unique(as.character(huc_sf$selected_huc))
  file <- list.files(paste0(data_dir, "nlcd/"), pattern = ".tif")
  if (any(grepl(paste0("^", huc12, ".*", year, ".*\\.tif$"), file))){
    message("Preparing NLCD...")
    if(length(file)>1){
      file <- file[grepl(paste0("^", huc12, "_.*", year, ".*\\.tif$"),file)]
    }
    nlcd <- terra::rast(paste0(data_dir, "nlcd/", file))
    nlcd <- terra::project(nlcd, huc_raster,method = "near")
  } else {
    stop("The required data file does not exist.  Run nsink_get_data().")
  }
  nlcd
}

#' Prepare SSURGO data for N-Sink
#'
#' Standardizes impervious data by transforming data, and reducing columns to
#' what is needed.
#'
#' @param huc_sf An sf object of the Watershed Boundaries Dataset HUC12
#' @param data_dir Base directory that contains N-Sink data folders.  Data may
#'                 be downloaded with the \code{\link{nsink_get_data}} function.
#' @return An sf object of the SSURGO data for the huc_sf with hydric data added.
#'
#' @import dplyr sf
#' @importFrom methods as
#' @importFrom utils read.csv
#' @importFrom rlang .data
#' @keywords  internal
nsink_prep_ssurgo <- function(huc_sf, data_dir) {

  huc12 <- unique(as.character(huc_sf$selected_huc))

  if (file.exists(paste0(data_dir, "ssurgo/", huc12,"_SSURGO_Mapunits.shp"))) {
    message("Preparing SSURGO...")
    ssurgo <- st_read(paste0(data_dir, "ssurgo/", huc12,
                             "_SSURGO_Mapunits.shp"), quiet = TRUE)
    ssurgo_tbl <- read.csv(paste0(
      data_dir, "ssurgo/", huc12,
      "_SSURGO_component.csv"
    ))
  } else if(file.exists(paste0(data_dir, "ssurgo/", huc12, "_ssurgo.gpkg"))){
    message("Preparing SSURGO...")
    ssurgo <- st_read(paste0(data_dir, "ssurgo/", huc12, "_ssurgo.gpkg"),
                      layer = "geometry", quiet = TRUE)
    ssurgo_tbl <- st_read(paste0(data_dir, "ssurgo/", huc12, "_ssurgo.gpkg"),
                          layer = "component", quiet = TRUE)
  } else {
    stop("The required data file does not exist.  Run nsink_get_data().")
  }
  ssurgo <- st_transform(ssurgo, st_crs(huc_sf))
  ssurgo <- rename_all(ssurgo, tolower)
  ssurgo <- mutate(ssurgo, mukey = as(.data$mukey, "character"))
  ssurgo_tbl <- mutate(ssurgo_tbl, mukey = as(.data$mukey, "character"))
  ssurgo_tbl <- select(ssurgo_tbl, "mukey", "cokey", "hydricrating", "comppct.r",
                       "compname", "drainagecl", "compkind", "localphase")


  # Limiting hydric removal to only land-based sources of removal
  # i.e. no removal from water polys in SSURGO and none from subaqueous soils
  ssurgo_tbl <- mutate(ssurgo_tbl, hydricrating =
                         case_when(.data$compname == "Water" ~
                                     "No",
                                   .data$drainagecl == "Subaqueous" ~
                                     "No",
                                   TRUE ~ .data$hydricrating))

  hydric_tbl <- filter(ssurgo_tbl, .data$hydricrating == "Yes")
  hydric_tbl <- group_by(hydric_tbl, .data$mukey, .data$hydricrating)
  hydric_tbl <- summarize(hydric_tbl, hydric_pct = sum(.data$comppct.r))
  hydric_tbl <- ungroup(hydric_tbl)
  ssurgo <- full_join(ssurgo, hydric_tbl, by = "mukey", relationship = "many-to-many")
  ssurgo <- filter(ssurgo, .data$musym != "Ws")
  ssurgo <- select(ssurgo, "areasymbol", "spatialver", "musym",
                   "mukey", "hydricrating", "hydric_pct")
  ssurgo
}

#' Prepare flow data for N-Sink
#'
#' Standardizes flow data from the EROM tables.
#'
#' @param data_dir Base directory that contains N-Sink data folders.  Data may
#'                 be downloaded with the \code{\link{nsink_get_data}} function.
#' @return A tibble of the flow data
#' @import dplyr
#' @importFrom rlang .data
#' @keywords  internal
nsink_prep_q <- function(data_dir) {
  erom_file <- list.files(paste0(data_dir, "erom/"), "EROM_MA0001.DBF",
                          recursive = TRUE, full.names = TRUE)
  if (length(erom_file == 1)) {
    message("Preparing stream flow...")
    q <- foreign::read.dbf(erom_file)
    q <- select(q, stream_comid = "ComID", q_cfs = "Q0001E")
    q <- mutate(q,
      q_cms = .data$q_cfs * 0.028316846592,
      mean_reach_depth = 0.2612 * (.data$q_cms^0.3966)
    )
    q <- mutate_if(q, is.factor, as.character())
  } else {
    stop("The required data file does not exist.  Run nsink_get_data().")
  }
  as_tibble(q)
}

#' Prepare time of travel data for N-Sink
#'
#' Standardizes time of travel from the NHDPlus VAA tables.
#'
#' @param data_dir Base directory that contains N-Sink data folders.  Data may
#'                 be downloaded with the \code{\link{nsink_get_data}} function.
#' @return A tibble of the time of travel data
#' @import dplyr
#' @importFrom rlang .data
#' @keywords  internal
nsink_prep_tot <- function(data_dir) {
  tot_file <- list.files(paste0(data_dir, "attr/"), "PlusFlowlineVAA.dbf",
                          recursive = TRUE, full.names = TRUE)
  if (length(tot_file) == 1) {
    message("Preparing time of travel...")
    tot <- foreign::read.dbf(tot_file)
    tot <- rename_all(tot, tolower)
    tot <- select(tot, stream_comid = "comid", totma = "totma",
                  "fromnode", "tonode", stream_order = "streamorde")
    tot <- mutate_if(tot, is.factor, as.character())
  } else {
    stop("The required data file does not exist.  Run nsink_get_data().")
  }
  as_tibble(tot)
}

#' Prepare lake morphology data for N-Sink
#'
#' Standardizes lake morphology from the lake morphology tables.
#'
#' @param data_dir Base directory that contains N-Sink data folders.  Data may
#'                 be downloaded with the \code{\link{nsink_get_data}} function.
#' @return A tibble of the lake morphology data
#' @import dplyr
#' @importFrom rlang .data
#' @keywords  internal
nsink_prep_lakemorpho <- function(data_dir) {
  lm_file <- list.files(paste0(data_dir, "attr/"),
                        "PlusWaterbodyLakeMorphology.dbf",
                         recursive = TRUE, full.names = TRUE)
  if (length(lm_file) == 1) {
    message("Preparing lake morphometry...")
    lakemorpho <- foreign::read.dbf(lm_file)
    lakemorpho <- rename_all(lakemorpho, tolower)
    lakemorpho <- rename(lakemorpho, lake_comid = "comid")
    lakemorpho <- mutate_if(lakemorpho, is.factor, as.character())
    lakemorpho <- select(lakemorpho, "lake_comid", "meandepth",
                         "lakevolume", "maxdepth", "meandused",
                         "meandcode", "lakearea")
  } else {
    stop("The required data file does not exist.  Run nsink_get_data().")
  }
  as_tibble(lakemorpho)
}


#' Remove open water portions of the HUC
#'
#' Uses SSURGO polys and the SSURGO musym = Ws to check for and remove any
#' portion of a HUC that is actually salt water.  This should account for the
#' coastal HUCs with large areas of open water.
#'
#' @param huc_sf An sf object of the Watershed Boundaries Dataset HUC12
#' @param data_dir Base directory that contains N-Sink data folders.  Data may
#'                 be downloaded with the \code{\link{nsink_get_data}} function.
#' @return An sf object of the HUC without salt water/open water area.
#' @import dplyr sf
#' @importFrom methods as
#' @importFrom utils read.csv
#' @importFrom rlang .data
#' @keywords  internal
nsink_remove_openwater <- function(huc_sf, data_dir){

  huc12 <- unique(as.character(huc_sf$selected_huc))
  if (file.exists(paste0(data_dir, "ssurgo/", huc12,"_SSURGO_Mapunits.shp"))) {

    ssurgo <- st_read(paste0(data_dir, "ssurgo/", huc12,
                             "_SSURGO_Mapunits.shp"), quiet = TRUE)
    ssurgo_tbl <- read.csv(paste0(
      data_dir, "ssurgo/", huc12,
      "_SSURGO_mapunit.csv"
    ))
  } else if(file.exists(paste0(data_dir, "ssurgo/", huc12, "_ssurgo.gpkg"))){
      ssurgo <- st_read(paste0(data_dir, "ssurgo/", huc12, "_ssurgo.gpkg"),
                        layer = "geometry", quiet = TRUE)
      ssurgo_tbl <-
        st_read(paste0(data_dir, "ssurgo/", huc12, "_ssurgo.gpkg"),
                layer = "component", quiet = TRUE)
  } else {
    stop("The required data file does not exist.  Run nsink_get_data().")
  }

  ssurgo <- st_transform(ssurgo, st_crs(huc_sf))
  ssurgo <- rename_all(ssurgo, tolower)
  ssurgo <- mutate(ssurgo, mukey = as(.data$mukey, "character"))
  ssurgo_tbl <- mutate(ssurgo_tbl, mukey = as(.data$mukey, "character"))
  ssurgo <- full_join(ssurgo, ssurgo_tbl, by = "mukey", relationship = "many-to-many")
  saltwater <- filter(ssurgo, .data$musym == "Ws")
  if(nrow(saltwater) > 0){
    huc_unit <- st_crs(huc_sf, parameters = TRUE)$ud_unit
    tol1 <- units::set_units(2, "m")
    tol1 <- units::set_units(tol1, huc_unit,
                             mode = "standard")
    pixel_area <- units::set_units(900, "m2")
    pixel_area <- units::set_units(pixel_area,
                                   huc_unit*huc_unit,
                                   mode = "standard")
    saltwater_buff <- st_buffer(saltwater, tol1)
    huc_ow_remove <- suppressMessages(st_difference(st_union(huc_sf),
                                                    st_union(saltwater_buff)))
    huc_ow_remove <- st_cast(huc_ow_remove, "POLYGON")

    huc_ow_remove <- huc_ow_remove[st_area(huc_ow_remove) > pixel_area]
  } else {
    huc_ow_remove <- huc_sf
  }
  st_as_sf(huc_ow_remove, data.frame(selected_huc = huc12))
}
