daily_debias_from_coeff <- function(daily.forecast, coeff.df, VarNames){
  # --------------------------------------
  # purpose: does linear debiasing from previously calculated coefficients
  # Creator: Laura Puckett, December 14 2018
  # --------------------------------------
  # @param: daily.forecast, dataframe of past forecasts at daily resolution
  # @param: coeff.df, the save coefficients for linear debaiasing for each meterological variable at daily resolution
if("fday.group" %in% colnames(daily.forecast)){
  grouping = c("fday.group","NOAA.member")
}else{
  grouping = c("date","NOAA.member")
}
  lin_mod <- function(col.for, coeff){
    intercept = coeff[1]
    slope = coeff[2]
    modeled = col.for*slope + intercept
    return(modeled)
  }
  debiased = daily.forecast %>% select(grouping)
  for(Var in 1:length(VarNames)){
    assign(VarNames[Var], value = as_data_frame(lin_mod(daily.forecast[,VarNames[Var]],
                                          coeff.df[,VarNames[Var]])))
    debiased <- cbind(debiased, get(VarNames[Var]))
  }
  return(debiased)
}

