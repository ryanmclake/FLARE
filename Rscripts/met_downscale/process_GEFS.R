# --------------------------------------
# purpose: process GEFS forecasts and save as input for lake downscaling
# Creator: Laura Puckett, December 21 2018
# contact: plaura1@vt.edu
# --------------------------------------
# summary: processes GEFS forecasts for three scenarios:
# (1) downscaled without noise addition
# (2) downscaled with noise addition
# (3) not downscaled ("out of box")
# Then, the output for each ensemble member is saved as a .csv file
# The function returns: (1) a list of the names of the .csv files and (2) a datframe of the processed output for all ensembles 
# --------------------------------------

process_GEFS <- function(file_name,
                         n_ds_members,
                         n_met_members,
                         sim_files_folder,
                         in_directory,
                         out_directory,
                         output_tz,
                         VarNames,
                         VarNamesStates,
                         replaceObsNames,
                         hrly.observations,
                         DOWNSCALE_MET,
                         FIT_PARAMETERS,
                         met_downscale_uncertainity,
                         WRITE_FILES,
                         downscaling_coeff){
  # -----------------------------------
  # 1. read in and reformat forecast data
  # -----------------------------------
  f <- paste0(in_directory,'/',file_name,'.csv')
  if(!file.exists(f)){
    print('Missing forecast file!')
    print(f)
    stop()
  }
  
  d <- read.csv(paste0(in_directory,'/',file_name,'.csv')) 
  full_time <- rep(NA,length(d$forecast.date)*6)
  begin_step <- as_datetime(head(d$forecast.date,1), tz = output_tz)
  end_step <- as_datetime(tail(d$forecast.date,1), tz = output_tz)
  if(date(begin_step)>as_date("2018-12-07")){
    for.input_tz = "GMT"
  }else{
    for.input_tz = "US/Eastern"
  }
  full_time <- seq(begin_step, end_step, by = "1 hour", tz = output_tz) # grid
  forecasts <- prep_for(d, input_tz = for.input_tz, output_tz = output_tz)
  time0 = min(forecasts$timestamp)
  time_end = max(forecasts$timestamp)
  
  # -----------------------------------
  # 2. process forecast according to desired method
  # -----------------------------------
  
  if(DOWNSCALE_MET == TRUE){
    ## Downscaling option
    print("Downscaling option")
    if(is.na(downscaling_coeff)){
      load(file = paste(out_directory,"/debiased.coefficients.RData", sep = ""))
    }else{
      load(file = paste(out_directory,"/",downscaling_coeff, sep = ""))
    }
    ds = downscale_met(forecasts,
                       debiased.coefficients,
                       VarNames,
                       VarNamesStates,
                       USE_ENSEMBLE_MEAN = FALSE,
                       PLOT = FALSE,
                       output_tz = output_tz)
    if(met_downscale_uncertainity == TRUE){
      ## Downscaling + noise addition option
      print("with noise")
      ds.noise = add_noise(debiased = ds,
                           cov = debiased.covar,
                           n_ds_members,
                           n_met_members,
                           VarNames = VarNames) %>%
        mutate(ShortWave = ifelse(ShortWaveOld == 0, 0, ShortWave),
               ShortWave = ifelse(ShortWave < 0, 0, ShortWave),
               RelHum = ifelse(RelHum <0, 0, RelHum),
               RelHum = ifelse(RelHum > 100, 100, RelHum),
               AirTemp = AirTemp - 273.15,
               WindSpeed = ifelse(WindSpeed <0, 0, WindSpeed)) %>%
        arrange(NOAA.member, dscale.member, timestamp)
      print("noise added")
      output = ds.noise
    }else{
      print("without noise")
      ds = ds %>% mutate(dscale.member = 0) %>%
        mutate(ShortWave = ifelse(ShortWave <0, 0, ShortWave),
               RelHum = ifelse(RelHum <0, 0, RelHum),
               RelHum = ifelse(RelHum > 100, 100, RelHum),
               AirTemp = AirTemp - 273.15) %>%
        arrange(NOAA.member, timestamp)
      output = ds
    }
    
  }else{
    ## "out of box" option
    print("out of box option")
    out.of.box = out_of_box(forecasts, VarNames) %>%
      dplyr::mutate(AirTemp = AirTemp - 273.15,
                    RelHum = ifelse(RelHum <0, 0, RelHum),
                    RelHum = ifelse(RelHum > 100, 100, RelHum),
                    ShortWave = ifelse(ShortWave < 0, 0, ShortWave)) %>%
      arrange(timestamp)
    output = out.of.box %>%
      dplyr::mutate(dscale.member = 0)
  }
  
  hrly.observations = hrly.observations %>%
    mutate(AirTemp = AirTemp - 273.15)
  obs.time0 = hrly.observations %>% filter(timestamp == time0)
  
  for(i in 1:length(VarNamesStates)){
    output[which(output$timestamp == time0),VarNamesStates[i]] = obs.time0[VarNamesStates[i]]
  }

  
  output.time0.6.hrs = output %>% filter(timestamp == time0 | timestamp == time0 + 6*60*60)
  
  states.output0.6.hrs = spline_to_hourly(output.time0.6.hrs,VarNamesStates)
  
  output <- output %>% full_join(states.output0.6.hrs, by = c("NOAA.member","dscale.member","timestamp"), suffix = c("",".splined")) %>%
    mutate(AirTemp = ifelse(is.na(AirTemp.splined), AirTemp, AirTemp.splined),
           WindSpeed = ifelse(is.na(WindSpeed.splined), WindSpeed, WindSpeed.splined),
           RelHum = ifelse(is.na(RelHum.splined), RelHum, RelHum.splined)) %>%
    select(-AirTemp.splined, WindSpeed.splined, RelHum.splined)
  output <- output %>% filter(timestamp < time_end)

  # -----------------------------------
  # 3. Produce output files
  # -----------------------------------
  met_file_list = NULL
  if(WRITE_FILES){
    print("Write Output Files")
    # Rain and Snow are currently not downscaled, so they are calculated here
    hrly.Rain.Snow = forecasts %>% dplyr::mutate(Snow = 0) %>%
      select(timestamp, NOAA.member, Rain, Snow) %>%
      repeat_6hr_to_hrly()

    
    write_file <- function(df){
      # formats GLM_climate, writes it as a .csv file, and returns the filename
      GLM_climate <- df %>% plyr::rename(c("timestamp" = "full_time")) %>%
        select(full_time, ShortWave, LongWave, AirTemp, RelHum, WindSpeed, Rain, Snow)
      GLM_climate[,"full_time"] = strftime(GLM_climate$full_time, format="%Y-%m-%d %H:%M", tz = attributes(GLM_climate$full_time)$tzone)
      colnames(GLM_climate) =  noquote(c("time", 
                                         "ShortWave",
                                         "LongWave",
                                         "AirTemp",
                                         "RelHum",
                                         "WindSpeed",
                                         "Rain",
                                         "Snow"))
      current_filename = paste0(out_directory,'/','met_hourly_',file_name,'_NOAA',NOAA.ens,'_ds',dscale.ens,'.csv')
      write.csv(GLM_climate,file = current_filename, row.names = FALSE, quote = FALSE)
      return(current_filename)
    }
    
    for(NOAA.ens in 1:21){
      Rain.Snow = hrly.Rain.Snow %>% filter(NOAA.member == NOAA.ens) %>%
        select(timestamp, Rain, Snow)
      if(DOWNSCALE_MET){
        if(met_downscale_uncertainity){ # downscale met with noise addition
          for(dscale.ens in 1:n_ds_members){
            GLM_climate_ds = output %>%
              filter(NOAA.member == NOAA.ens & dscale.member == dscale.ens) %>%
              arrange(timestamp) %>%
              select(timestamp, VarNames)
            GLM_climate_ds = full_join(Rain.Snow, GLM_climate_ds, by = "timestamp")
            current_filename = write_file(GLM_climate_ds)
            met_file_list = append(met_file_list, current_filename)
          }
        }else{ # downscale met, no noise addition
          dscale.ens = 0
          GLM_climate_ds = output %>%
            filter(NOAA.member == NOAA.ens) %>%
            arrange(timestamp) %>%
            select(timestamp, VarNames)
          GLM_climate_ds = full_join(Rain.Snow, GLM_climate_ds, by = "timestamp")
          current_filename = write_file(GLM_climate_ds)
          met_file_list = append(met_file_list, current_filename)
        }
      }else{ # out of box
        dscale.ens = 0
        GLM_climate_no_ds = output %>%
          filter(NOAA.member == NOAA.ens) %>%
          arrange(timestamp) %>%
          select(timestamp, Rain, Snow, VarNames)
        current_filename = write_file(GLM_climate_no_ds)
        met_file_list = append(met_file_list, current_filename)
      }
    }
  }
  return(list(met_file_list, output))
}










