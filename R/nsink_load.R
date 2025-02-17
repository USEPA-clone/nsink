#' Load an existing N-Sink analysis folder
#'
#'
#' @param input_folder Folder that contains nsink files produced by
#'                     \code{\link{nsink_build}}
#' @param base_name A base name used to assign objects to the global environment.
#' @param projection An optional CRS specified as a either an
#'                   EPSG code (as numeric) or WKT (as string).
#'                   Useful if projection is returned as unknown.
#' @param ... Passes to \code{\link{nsink_calc_removal}} for the off network
#'            arguments: \code{off_network_lakes}, \code{off_network_streams},
#'            and \code{off_network_canalsditches}.
#' @export
#' @return Creates several lists in the global environment that would normally
#'         be created when running an N-Sink analysis.  These include:
#'         a \code{\link{nsink_prep_data}} object,
#'         a \code{\link{nsink_calc_removal}} object, and a
#'         \code{\link{nsink_generate_static_maps}} object
#' @importFrom sf st_read
#' @importFrom raster raster projection readAll
#' @examples
#' \dontrun{
#' library(nsink)
#'
#' aea <- 5072
#' nsink_build(nsink_get_huc_id("Niantic River")$huc_12, aea,
#'             output_folder = "nsink_output", samp_dens = 300)
#' nsink_load(input_folder = "nsink_output",
#'            base_name = "nsink_")
#' }
nsink_load <- function(input_folder, base_name = "nsink_", projection = NULL
                       , ...){

  if(!dir.exists(input_folder)){
    stop(paste("The input folder,", input_folder, "does not currently exist, please create it with nsink_build."))
  }
  input_folder_orig <- input_folder
  input_folder <- nsink_fix_data_directory(input_folder)
  message("Reading in built files...")
  huc_sf <- st_read(paste0(input_folder, "huc.shp"), quiet = TRUE)
  res <- units::set_units(30, "m")
  res <- units::set_units(res, st_crs(huc_sf, parameters = TRUE)$ud_unit,
                          mode = "standard")
  prep <- list(streams = st_read(paste0(input_folder,"streams.shp"), quiet = TRUE),
               lakes = st_read(paste0(input_folder,"lakes.shp"), quiet = TRUE),
               fdr = terra::rast(paste0(input_folder, "fdr.tif")),
               impervious = terra::rast(paste0(input_folder, "impervious.tif")),
               nlcd = terra::rast(paste0(input_folder, "nlcd.tif")),
               ssurgo = st_read(paste0(input_folder,"ssurgo.shp"), quiet = TRUE),
               q = read.csv(paste0(input_folder, "q.csv")),
               tot = read.csv(paste0(input_folder, "tot.csv")),
               lakemorpho = read.csv(paste0(input_folder, "lakemorpho.csv")),
               huc = huc_sf,
               raster_template = terra::rast(huc_sf,
                                                resolution = as.numeric(res),
                                                crs = st_crs(huc_sf)$wkt)
               )

  # The shapefile driver butchers output names, need to restore them.
  names(prep$streams) <- c("stream_comid", "fdate", "resolution", "gnis_id",
                           "gnis_name", "reachcode", "flowdir",
                           "lake_comid", "ftype", "fcode",
                           "enabled", "gnis_nbr", "geometry")
  names(prep$lakes) <- c("lake_comid", "fdate", "resolution", "gnis_id", "gnis_name",
                         "areasqkm", "elevation", "reachcode", "ftype", "fcode", "shape_leng",
                         "shape_area", "geometry")
  names(prep$ssurgo) <- c("areasymbol", "spatialver", "musym", "mukey", "hydricrating",
                          "hydric_pct", "geometry")


  suppressMessages(removal <- nsink_calc_removal(prep, ...))
  #load(paste0(input_folder,"removal.rda"))
  #removal <- get("nsink_removal")
  message("Reading in static maps...")
  static <- list(removal_effic = terra::rast(paste0(input_folder,
                                                       "removal_effic.tif")),
                 loading_idx = terra::rast(paste0(input_folder,
                                                     "loading_idx.tif")),
                 transport_idx = terra::rast(paste0(input_folder,
                                                       "transport_idx.tif")),
                 delivery_idx = terra::rast(paste0(input_folder,
                                                      "delivery_idx.tif")))

  fix_proj <- function(my_list, prj){

    my_class <- unlist(lapply(my_list, function(x) class(x)[1]))
    my_sf <- which(my_class == "sf")
    my_raster <- which(grepl("Raster", my_class))
    my_sf_new_proj <- which(unlist(lapply(my_list[my_sf],
                                          function(x)
                                            st_crs(prj) !=
                                            st_crs(x))))
    my_raster_new_prj <- which(unlist(lapply(my_list[my_raster],
                                             function(x) st_crs(prj) != st_crs(x))))
    fix_sf <- my_sf[my_sf_new_proj]
    fix_raster <- my_raster[my_raster_new_prj]
    for(i in fix_raster){
      my_list[[i]] <- terra::project(my_list[[i]], crs = st_crs(prj)$wkt)
    }
    for(i in fix_sf){
      my_list[[i]] <- st_transform(my_list[[i]], crs = st_crs(prj)$wkt)
    }
    my_list
  }

  #Deal with possible CRS mismatches due to proj4 write and read
  if(!is.null(projection)){
    projection_template <- st_transform(prep[["streams"]], crs = projection)
    #prep <- fix_proj(prep, projection_template)
    prep <- list(streams = st_transform(prep[["streams"]], crs = projection),
                 lakes = st_transform(prep[["lakes"]], crs = projection),
                 fdr = prep[["fdr"]],
                 impervious = terra::project(prep[["impervious"]],
                                             st_crs(projection_template)$wkt),
                 nlcd = terra::project(prep[["nlcd"]],
                                       st_crs(projection_template)$wkt),
                 ssurgo = st_transform(prep[["ssurgo"]], crs = projection),
                 q = prep[["q"]],
                 tot = prep[["tot"]],
                 lakemorpho = prep[["lakemorpho"]],
                 huc = st_transform(prep[["huc"]], crs = projection),
                 raster_template = terra::project(prep[["raster_template"]],
                                                  st_crs(projection_template)$wkt))

    removal <- list(raster_method =
                      list(removal = terra::project(removal$raster_method$removal,
                                     st_crs(projection_template)$wkt),
                           type = terra::project(removal$raster_method$type,
                                                    st_crs(projection_template)$wkt)),
                    land_off_network_removal =
                      st_transform(removal[["land_off_network_removal"]],
                                   crs = projection),
                    land_off_network_removal_type =
                      st_transform(removal[["land_off_network_removal_type"]],
                                   crs = projection),
                    network_removal = st_transform(removal[["network_removal"]],
                                                   crs = projection))
    static <- list(removal_effic =
                     terra::project(static[["removal_effic"]],
                                    st_crs(projection_template)$wkt),
                   loading_idx =
                     terra::project(static[["loading_idx"]],
                                    st_crs(projection_template)$wkt),
                   transport_idx =
                     terra::project(static[["transport_idx"]],
                                    st_crs(projection_template)$wkt),
                   delivery_idx =
                     terra::project(static[["delivery_idx"]],
                                    st_crs(projection_template)$wkt))
  }

  assign(paste0(base_name,"data"), prep, envir = parent.frame())
  assign(paste0(base_name,"removal"), removal, envir = parent.frame())
  assign(paste0(base_name,"static_maps"), static, envir = parent.frame())

  message(paste0("The nsink folder, ", input_folder_orig,
                 " was loaded into:\n ",
                 paste(ls(pattern = base_name, envir = parent.frame()),
                       collapse = "\n "), "."))
}


