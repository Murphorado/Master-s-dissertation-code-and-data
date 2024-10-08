# Set working directory and open relevant packages
setwd("C:/Users/murph/OneDrive - University of Edinburgh/Masters/Dissertation/R")
library(tidyverse) # Data manipulation and figures
library(lme4) # Mixed models
library(ggeffects) # Predictions from models
library(AICcmodavg) # AICc values
library(ggplot2)
library(dplyr) # data manipulation
library(lmerTest)
library(effects)
library(sjPlot)
library(paletteer)
library(patchwork)
library(DHARMa)

# Import the blue tit phenology and clutch size data
birds <- read.csv("datasets/birds.csv")
View(birds)

# Drop any rows with zero values for species or first egg date. I did this to only include species which were confirmed and to eliminate unoccupied nestboxes.
# NA values for fed = 2014 BAD2, BAD4, LVN4, LVN6, GLF3, MCH1, MCH2, MCH4, PTH2, PTH5, STY2, STY3, STY4, BIR1, BIR3, BIR5, DUN2, DUN3, DUN4

birds_clean_fed <- birds %>% 
  drop_na(species, fed)

# Only include rows with blue tit species.
birds_clean_fed <- birds_clean_fed %>%
  filter(species == "bluti")

# Filter the dataset to remove rows where cs < 2. Dropped any rows with less than 2 for clutch size to make sure this was actually a breeding attempt
birds_clean_fed <- birds_clean_fed %>%
  filter(cs >= 2)

# Create a "site_year" column within the "birds_clean_fed" dataset. This is so I can later combine with the temperature dataset in the sliding window analysis based on the unique values for each site and year. 
birds_clean_fed$site_year <- paste(birds_clean_fed$site, birds_clean_fed$year, sep = " ")

## Adding unique IDs for female birds to bird phenology data from adults dataset.

# Creates a "site_year_box" column within the "birds_clean_fed" dataset. This will allow me to later combine with the "adults" dataset.
birds_clean_fed$site_year_box <- paste(birds_clean_fed$site_year, birds_clean_fed$box, sep = " ")

adults <- read.csv("C:/Users/murph/Dropbox/master_data/blue tits/Adults.csv")
adults$site_year_box <- paste(adults$site, adults$year, adults$box, sep=" ")

# Combine datasets based on site_year_box and sex columns with "F" in them.

# Filter the adults dataset for female birds
adults_female <- adults %>% filter(sex == "F")

# Select only the relevant columns
adults_female <- adults_female %>% select(site_year_box, ring)

# Merge the datasets based on the site_year_box column
birds_clean_fed <- birds_clean_fed %>% 
  left_join(adults_female, by = "site_year_box")

# Assign unique IDs to NA values in the 'ring' column. I used ID_row number. So these individuals can still be included as unique replicates for the random effect of individual.
birds_clean_fed <- birds_clean_fed %>%
  mutate(ring = if_else(is.na(ring), paste0("ID_", row_number()), ring))

# Import temperature data

temperature <- read.csv("datasets/temperature.csv")

# Averages the temperature data in columns starting with "X" which have the same values of both "site" and "year". This is to get an average temperature every hour for each site across both loggers.
temperature <- temperature %>%
  group_by(site, year) %>%
  summarize(across(starts_with("X"), mean, na.rm = TRUE))

# Creates a "site_year" column within the "temperature" dataset. 
temperature$site_year <- paste(temperature$site, temperature$year, sep = " ")

# Get the column names of the dataset
cols <- colnames(temperature)
# Reposition the last column to the third position
temperature <- temperature %>%
  select(all_of(cols[1:2]), site_year, all_of(cols[3:(length(cols)-1)]))

# Replace NaN with NA in columns that start with "X"
temperature <- temperature %>%
  mutate(across(starts_with("X"), ~ ifelse(is.nan(.), NA, .)))

# Initialize a list to store the mean daily temperatures for each site_year
mean_daily_temperatures_list <- list()

# Group by 'site_year' and process each group separately
grouped_data <- temperature %>% group_by(site_year)

# Calculate the mean daily temperature for each 'site_year'
grouped_data <- grouped_data %>% do({
  data <- .
  # Skip the first three columns
  temperature_trimmed <- data[, -c(1:3)]
  num_cols <- ncol(temperature_trimmed)
  num_full_days <- num_cols %/% 24
  mean_daily_temperatures <- numeric(num_full_days)
  
  for (i in 1:num_full_days) {
    start_col <- (i - 1) * 24 + 1
    end_col <- i * 24
    daily_chunk <- temperature_trimmed[, start_col:end_col]
    mean_daily_temperatures[i] <- mean(unlist(daily_chunk), na.rm = TRUE)
  }
  
  data.frame(Day = 1:num_full_days, Mean_Daily_Temperature = mean_daily_temperatures)
})

# Convert to wide format with days starting from Day 46
mean_daily_temperatures_wide <- grouped_data %>%
  mutate(Day = paste0("Day_", 45 + Day)) %>%  # Adjust day numbers to start from 46
  pivot_wider(names_from = Day, values_from = Mean_Daily_Temperature)

temperature <- mean_daily_temperatures_wide

fed_start_col <- seq(340,2810,168)
# list of values from column 60 (day 60 - 1st Mar)(avoids NA values for temp) to 121 (day 121 - 1st May - average fed) in increments of 168 - weekly start date intervals 

fed_duration <- seq(168,2810,168)
# list of values from 168 to 2449 in increments of 168 - duration of 1 week or more increasing by 1 week

fed_windows <- data.frame(start_col=rep(fed_start_col, each=length(fed_duration)),
                          duration=rep(fed_duration, length(fed_start_col)))
# this repeats every start date for the number of durations there are and vice versa to pair all options

fed_windows$end_col <- fed_windows$start_col+fed_windows$duration-1 
# working out the end column, -1 is included because the start date is included in the window

fed_windows <- fed_windows[-which(fed_windows$end_col>2810),]
# removing any windows that extend past the available data

# Give the windows an ID so it's clear which window they test
fed_windows$window_ID <- paste0(colnames(temperature)[fed_windows$start_col],
                                "_",fed_windows$duration,"hours") 
# Here we've taken the column name for the start date of the window and combined it with the duration of the window 
# The ID now says which ordinal date the window will start on and how long it is in hours

# create and empty plot with x axis for the number of days of temp data and y for each window
plot(NA, xlim=c(340,2810), ylim=c(1,nrow(fed_windows)), xlab="Column number", ylab="Different windows") 
# Use a loop to plot each window
for(i in 1:nrow(fed_windows)){ 
  points(fed_windows[i,c("start_col","end_col")], c(i,i), type="l") 
}

fed_base_mod <- lmer(fed ~ 1 + (1|site) + (1|year) + (1|ring), birds_clean_fed, REML=F)
summary(fed_base_mod)

# Make an empty data frame that the results will go into
fed_slidwin <- data.frame(matrix(NA, ncol=8, nrow=nrow(fed_windows)))

# Name the columns
colnames(fed_slidwin) <- c("window_ID", "start_date", "end_date", "deltaAICc", "temp_coef", "temp_SE", "deviation_coef", "deviation_SE")

for(i in 1:nrow(fed_windows)){
  
  #Extract relevant temperature data
  temp_dat <- data.frame(site_year = temperature$site_year,  
                         window_temp = rowMeans(temperature[,fed_windows$start_col[i]
                                                            :fed_windows$end_col[i]], na.rm=TRUE))
  
  # Join temperature and bird phenology data
  fed_windtemp <- left_join(birds_clean_fed, temp_dat, by="site_year")
  
  site_avg_temps <- fed_windtemp %>%
    group_by(site) %>%
    summarize(site_avg_temps = mean(window_temp, na.rm = TRUE))
  
  fed_windtemp <- left_join(fed_windtemp, site_avg_temps, by = "site")
  
  fed_windtemp$deviations<-fed_windtemp$window_temp - fed_windtemp$site_avg_temps
  
  # Run the model 
  mod <- lmer(fed ~ 1 + site_avg_temps + deviations + (1|site) + (1|year) + (1|ring), fed_windtemp, REML=F)
  
  # Store the relevant information
  fed_slidwin$window_ID[i] <- fed_windows$window_ID[i] 
  fed_slidwin$start_date[i] <- fed_windows$start_col[i]
  fed_slidwin$end_date[i] <- fed_windows$end_col[i] 
  fed_slidwin$deltaAICc[i] <- AICc(mod)-AICc(fed_base_mod)
  fed_slidwin$temp_coef[i] <- summary(mod)$coefficients["site_avg_temps", "Estimate"]  
  fed_slidwin$temp_SE[i] <- summary(mod)$coefficients["site_avg_temps","Std. Error"]
  fed_slidwin$deviation_coef[i] <- summary(mod)$coefficients["deviations", "Estimate"]
  fed_slidwin$deviation_SE[i] <- summary(mod)$coefficients["deviations", "Std. Error"]
  
  
  # remove elements that were specific to this run of the sliding window
  rm(temp_dat, fed_windtemp, mod)
  
}
View(fed_slidwin)

## Most important window = day 67 (Mar 8th) - day 130 (10th May)

# blank plot with axis from min to max values for dates and AICc
plot(NA, xlim=c(min(fed_slidwin$start_date),max(fed_slidwin$end_date)),
     ylim=c(min(fed_slidwin$deltaAICc),max(fed_slidwin.4$deltaAICc)), 
     xlab="Hours", ylab="deltaAICc") 

# use loop to draw the lines
for(i in 1:nrow(fed_slidwin)){
  points(c(fed_slidwin$start_date[i],fed_slidwin$end_date[i]),
         c(fed_slidwin$deltaAICc[i],fed_slidwin$deltaAICc[i]),type="l") 
} 

# line at 2 AICc above the lowest
abline(h=(min(fed_slidwin$deltaAICc)+2), col="red", lty="dashed")

# Row number for the window with the lowest AIC
fed_wind_row <- which(fed_slidwin$deltaAICc==min(fed_slidwin$deltaAICc))

# ID for the best window
fed_wind_ID <- fed_slidwin$window_ID[fed_wind_row] 

#The row number is the same in the fed_windows and fed_slidwin dataframes
fed_wind_row

which(fed_windows$window_ID==fed_wind_ID)

# Mean temperature during the identified window
fed_best_temp_wind <- data.frame(site_year = temperature$site_year,  
                                 best_temp = rowMeans(temperature[,fed_windows$start_col[fed_wind_row]:fed_windows$end_col[fed_wind_row]])) 

# Join temperature and bird phenology data
fed_best_temp <- left_join(birds_clean_fed, fed_best_temp_wind, by="site_year")

fed_best_temp <- fed_best_temp %>% 
  drop_na(best_temp)

## Within-subject centering - calculate the mean temperature across sites and the annual deviations from this

best_site_avg_temps <- fed_best_temp %>%
  group_by(site) %>%
  summarize(best_site_avg_temps = mean(best_temp, na.rm = TRUE))

fed_best_temp <- left_join(fed_best_temp, best_site_avg_temps, by = "site")

fed_best_temp$deviations<-fed_best_temp$best_temp - fed_best_temp$best_site_avg_temps

# Run the same model as before but with REML=TRUE - best temp window is day 57 - 116 (26th Feb - 26th April)
fed_mod <- lmer(fed~best_site_avg_temps+deviations+(1|year)+(1|site)+(1|ring), fed_best_temp, REML=TRUE) 
summary(fed_mod)

caterpillars <- read.csv("datasets/caterpillars.csv") # Import dataset
# Extract relevant columns
caterpillars <- data.frame(year=caterpillars$year, site=caterpillars$site, tree=caterpillars$tree, 
                           tree.species=caterpillars$tree.species, date=caterpillars$date, caterpillars=caterpillars$caterpillars, 
                           caterpillar.mass=caterpillars$caterpillar.mass,beats=caterpillars$beats)

View(caterpillars)

# Create site_year column
caterpillars$site_year <- paste(caterpillars$site, caterpillars$year, sep=" ")

# Calculate the total number of caterpillars and the number of unique trees for each site_year. This is so I can calculate a standardised "caterpillars per tree" metric for each "site_year".
caterpillars_std <- caterpillars %>%
  group_by(site_year) %>%
  summarize(
    total_caterpillars = sum(caterpillars, na.rm = TRUE),
    beats_per_siteyear = sum(beats)
  ) %>%
  mutate(caterpillars_per_tree = total_caterpillars / beats_per_siteyear)

View(caterpillars_std)

caterpillars_std <- caterpillars_std %>%
  separate(site_year, into = c("site", "year"), sep = " ", remove = FALSE)

caterpillars_std <- caterpillars_std %>%
  group_by(site) %>%
  mutate(site_avg_cater = mean(caterpillars_per_tree, na.rm = TRUE))

caterpillars_std$cater_devs <- caterpillars_std$caterpillars_per_tree - caterpillars_std$site_avg_cater

# Add the caterpillars_per_tree to the best temperature window data to add it as a fixed effect in the model

# Ungroup the data frame and select all columns except 'site' and 'year'
caterpillars_std <- caterpillars_std %>%
  ungroup() %>%
  select(-site, -year)

# Perform the left join without including the 'site' and 'year' columns from 'caterpillars_std_clean'
fed_best_window.cat <- left_join(fed_best_temp, caterpillars_std, by = "site_year")
fed_mod.cat <- lmer(fed~best_site_avg_temps+deviations+site_avg_cater+cater_devs+(1|year)+(1|site)+(1|ring), fed_best_window.cat, REML=TRUE)
summary(fed_mod.cat)
summary(fed_mod)

trees <- read.csv("datasets/trees.csv") # Import dataset

# Remove any missing values for tree fbb
View(trees)
trees$fbb <- as.numeric(trees$fbb)
trees <- trees %>% drop_na(fbb)

# Create a "site_year" column in the trees dataset to combine it later with the mean fbb.
trees$site_year <- paste(trees$site, trees$year, sep=" ")
trees <- data.frame(treeID=trees$treeID, 
                    speciesgroup=trees$speciesgroup, fbb=trees$fbb, cbb=trees$cbb, 
                    flf=trees$flf, clf=trees$clf, site_year=trees$site_year, site=trees$site, year=trees$year)

# Calculate mean first bud burst for each "site_year"
mean_fbb <- trees %>%
  group_by(site_year) %>%
  summarize(mean_fbb = mean(fbb, na.rm = TRUE))

# Join with trees dataset
trees <- left_join(trees, mean_fbb, by="site_year")

site_avg_fbb <- trees %>%
  group_by(site) %>%
  summarize(site_avg_fbb = mean(fbb, na.rm = TRUE))

trees <- left_join(trees, site_avg_fbb, by = "site")

trees$fbb_deviations<-trees$mean_fbb - trees$site_avg_fbb

# Filter for birch species and calculate the mean fbb for each site_year
mean_fbb_birch <- trees %>%
  filter(speciesgroup == "Birch") %>%
  group_by(site_year) %>%
  summarize(mean_fbb_birch = mean(fbb, na.rm = TRUE))

trees <- left_join(trees, mean_fbb_birch, by="site_year")

site_avg_birch_fbb <- trees %>%
  group_by(site) %>%
  summarize(site_avg_birch_fbb = mean(mean_fbb_birch, na.rm = TRUE))

trees <- left_join(trees, site_avg_birch_fbb, by = "site")

trees$birch_fbb_deviations<-trees$mean_fbb_birch - trees$site_avg_birch_fbb

# Identify all site_years that have at least one Birch tree
birch_site_years <- trees %>%
  filter(speciesgroup == "Birch") %>%
  select(site_year) %>%
  distinct()

# Filter the original dataset to include only those site_years with Birch trees
filtered_dataset <- trees %>%
  filter(site_year %in% birch_site_years$site_year)

mean_fbb <- trees %>% group_by(site_year) %>% summarize(mean_fbb = mean(mean_fbb, na.rm=TRUE))
fed_best_window.cat.tree <- left_join(fed_best_window.cat, mean_fbb, by="site_year")

site_avg_fbb <- trees %>% group_by(site_year) %>% summarize(site_avg_fbb = mean(site_avg_fbb, na.rm=TRUE))
fed_best_window.cat.tree <- left_join(fed_best_window.cat.tree, site_avg_fbb, by="site_year")

fbb_deviations <- trees %>% group_by(site_year) %>% summarize(fbb_deviations = mean(fbb_deviations, na.rm=TRUE))
fed_best_window.cat.tree <- left_join(fed_best_window.cat.tree, fbb_deviations, by="site_year")

mean_fbb_birch <- trees %>% group_by(site_year) %>% summarize(mean_fbb_birch = mean(mean_fbb_birch, na.rm=TRUE))
fed_best_window.cat.tree <- left_join(fed_best_window.cat.tree, mean_fbb_birch, by="site_year")

birch_fbb_deviations <- trees %>% group_by(site_year) %>% summarize(birch_fbb_deviations = mean(birch_fbb_deviations, na.rm=TRUE))
fed_best_window.cat.tree <- left_join(fed_best_window.cat.tree, birch_fbb_deviations, by="site_year")

site_avg_birch_fbb <- trees %>% group_by(site_year) %>% summarize(site_avg_birch_fbb = mean(site_avg_birch_fbb, na.rm=TRUE))
fed_best_window.cat.tree <- left_join(fed_best_window.cat.tree, site_avg_birch_fbb, by="site_year")

fed_best_window.cat.tree <- fed_best_window.cat.tree %>%
  rename(Site_average_temperature = best_site_avg_temps, Annual_temperature_deviations = deviations, Site_average_caterpillars=site_avg_cater, Annual_caterpillar_deviations=cater_devs, Site_average_fbb=site_avg_fbb, Annual_fbb_deviations=fbb_deviations, Site_average_birch_fbb=site_avg_birch_fbb, Annual_birch_fbb_deviations=birch_fbb_deviations)

# Run model with both caterpillars per tree and average fbb as fixed effects
fed_mod.cat.tree <- lmer(fed~Site_average_temperature+Annual_temperature_deviations+Site_average_caterpillars+Annual_caterpillar_deviations+Site_average_fbb+Annual_fbb_deviations+(1|year)+(1|site)+(1|ring), fed_best_window.cat.tree, REML=TRUE)
summary(fed_mod.cat.tree)

# Run model with both caterpillars per tree and average fbb as fixed effects
fed_mod.cat.birch <- lmer(fed~Site_average_temperature+Annual_temperature_deviations+Site_average_caterpillars+Annual_caterpillar_deviations+Site_average_birch_fbb+Annual_birch_fbb_deviations+(1|year)+(1|site)+(1|ring), fed_best_window.cat.tree, REML=TRUE)
summary(fed_mod.cat.birch)

# Get the row indices of observations included in the model
included_rows <- as.numeric(rownames(model.frame(fed_mod.cat.birch)))

# Identify the rows that were excluded by comparing with the original dataset
all_rows <- 1:nrow(fed_best_window.cat.tree)
excluded_rows <- setdiff(all_rows, included_rows)

# Drop the excluded (dropped) rows from the original dataset
cleaned_data <- fed_best_window.cat.tree[included_rows, ]

# Refit both models on the cleaned dataset
fed_mod.cat.tree_cleaned <- lmer(fed ~ Site_average_temperature + Annual_temperature_deviations +
                                   Site_average_caterpillars + Annual_caterpillar_deviations +
                                   Site_average_fbb + Annual_fbb_deviations +
                                   (1 | year) + (1 | site) + (1 | ring), 
                                 data = cleaned_data, REML = TRUE)

fed_mod.cat.birch_cleaned <- lmer(fed ~ Site_average_temperature + Annual_temperature_deviations +
                                    Site_average_caterpillars + Annual_caterpillar_deviations +
                                    Site_average_birch_fbb + Annual_birch_fbb_deviations +
                                    (1 | year) + (1 | site) + (1 | ring), 
                                  data = cleaned_data, REML = TRUE)


summary(fed_mod.cat.birch_cleaned)

AICc(fed_mod.cat.tree_cleaned)
AICc(fed_mod.cat.birch_cleaned)

mean_fbb_birch <- trees %>% group_by(site_year) %>% summarize(mean_fbb_birch = mean(mean_fbb_birch, na.rm=TRUE))
fed_best_window.cat.tree <- left_join(fed_best_window.cat.tree, mean_fbb_birch, by="site_year")

View(fed_best_window.cat.tree)

fed_mod.cat.tree.birch <- lmer(fed~best_site_avg_temps+deviations+log1p(caterpillars_per_tree)+mean_fbb+mean_fbb_birch+(1|year)+(1|site)+(1|ring), fed_best_window.cat.tree, REML=TRUE)
summary(fed_mod.cat.tree.birch)

# Remove rows with NA values in best_site_avg_temps
fed_best_window.cat.tree <- fed_best_window.cat.tree[!is.na(fed_best_window.cat.tree$best_site_avg_temps), ]

testDispersion(fed_mod.cat.tree)
simulationOutput <- simulateResiduals(fittedModel = fed_mod.cat.tree, plot = F)
residuals(simulationOutput)
plot(simulationOutput)
testOutliers(simulationOutput, type="bootstrap")

sum(fed_best_window.cat.tree$Annual_caterpillar_deviations > 3, na.rm = TRUE)
fed_best_window.cat.tree <- fed_best_window.cat.tree %>% filter(Annual_caterpillar_deviations < 3)

fed_mod.cat.tree.2 <- lmer(fed~best_temp+Site_average_temperature+Site_average_caterpillars+Annual_caterpillar_deviations+Site_average_fbb+Annual_fbb_deviations+(1|year)+(1|site)+(1|ring), fed_best_window.cat.tree, REML=TRUE)
summary(fed_mod.cat.tree.2)

fed_mod.cat.tree.3 <- lmer(fed~Site_average_temperature+Annual_temperature_deviations+Site_average_caterpillars+Annual_caterpillar_deviations+mean_fbb+Site_average_fbb+(1|year)+(1|site)+(1|ring), fed_best_window.cat.tree, REML=TRUE)
summary(fed_mod.cat.tree.3)

# Store the slope and confidence intervals 
fed_site_avg_temps_coef <- summary(fed_mod.cat.tree)$coefficients["Site_average_temperature","Estimate"] 
fed_site_avg_temps_confint <- confint(fed_mod.cat.tree)["Site_average_temperature",]

fed_deviations_coef <- summary(fed_mod.cat.tree)$coefficients["Annual_temperature_deviations", "Estimate"]
fed_deviations_confint <- confint(fed_mod.cat.tree)["Annual_temperature_deviations",]

fed_cater_coef <- summary(fed_mod.cat.tree.diag)$coefficients["log1p(caterpillars_per_tree)","Estimate"]
fed_cater_confint <- confint(fed_mod.cat.tree.diag)["log1p(caterpillars_per_tree)",]

fed_site_avg_fbb_coef <- summary(fed_mod.cat.tree)$coefficients["Site_average_fbb","Estimate"]
fed_site_avg_fbb_confint <- confint(fed_mod.cat.tree)["Site_average_fbb",]

fed_fbb_deviations_coef <- summary(fed_mod.cat.tree)$coefficients["Annual_fbb_deviations","Estimate"]
fed_fbb_deviations_confint <- confint(fed_mod.cat.tree)["Annual_fbb_deviations"]

# This shows the mean and 95% confidence intervals for the slope in units of days per°C
fed_site_avg_temps_coef 
fed_site_avg_temps_confint

fed_deviations_coef
fed_deviations_confint

fed_mean_fbb_coef
fed_mean_fbb_confint

# Use ggpredict to get estimates of first egg date across the range of temperatures included in the data
pred_fed_site <- ggpredict(fed_mod.cat.tree, "Site_average_temperature")
pred_fed_dev <- ggpredict(fed_mod.cat.tree, "Annual_temperature_deviations")
pred_fed_cater <- ggpredict(fed_mod.cat.tree.diag, "caterpillars_per_tree")
pred_fed_fbb_site <- ggpredict(fed_mod.cat.tree, "Site_average_fbb")
pred_fed_fbb_dev <- ggpredict(fed_mod.cat.tree, "Annual_fbb_deviations")

#Plot the mean prediction and CIs with the data
fed_site_temp_plot <- ggplot(pred_fed_site, aes(x,predicted))+ 
  geom_line(lwd=1.2, colour="darkred")+ 
  geom_point(data=fed_best_window.cat.tree, aes(Site_average_temperature, fed), colour="red")+ 
  geom_ribbon(data=pred_fed_site, aes(x=x, ymin=conf.low, ymax=conf.high), alpha=0.25, colour="darkred")+
  scale_fill_paletteer_d("nationalparkcolors::Acadia")+
  xlab("Mean site temperature (°C)")+ 
  ylab("First egg date (1 = 1st Jan)")+ 
  theme_bw()

#Plot the mean prediction and CIs with the data
fed_dev_temp_plot <- ggplot(pred_fed_dev, aes(x,predicted))+ 
  geom_line(lwd=1.2, colour="red")+ 
  geom_point(data=fed_best_window.cat.tree, aes(Annual_temperature_deviations, fed), colour="#FF7F7F")+ 
  geom_ribbon(data=pred_fed_dev, aes(x=x, ymin=conf.low, ymax=conf.high), alpha=0.25, colour="red")+
  scale_fill_paletteer_d("nationalparkcolors::Acadia")+
  xlab("Annual deviations from site mean temperature (°C)")+ 
  ylab("First egg date (1 = 1st Jan)")+ 
  theme_bw()

temp_plots <- fed_site_temp_plot + fed_dev_temp_plot
print(temp_plots)

#Plot the mean prediction and CIs with the data
ggplot(pred_fed_cater, aes(x,predicted))+ 
  geom_line(lwd=1.2, colour="#006D5B")+ 
  geom_point(data=fed_best_window.cat.tree.diag, aes(caterpillars_per_tree, fed), colour="#77DD77")+ 
  geom_ribbon(data=pred_fed_cater, aes(x=x, ymin=conf.low, ymax=conf.high), alpha=0.25, colour="#006D5B")+
  scale_fill_paletteer_d("nationalparkcolors::Acadia")+
  xlab("Caterpillars per beat")+ 
  ylab("First egg date")+ 
  theme_bw()

#Plot the mean prediction and CIs with the data
fed_site_fbb_plot <- ggplot(pred_fed_fbb_site, aes(x,predicted))+ 
  geom_line(lwd=1.2, colour="darkblue")+ 
  geom_point(data=fed_best_window.cat.tree, aes(Site_average_fbb, fed), colour="blue")+ 
  geom_ribbon(data=pred_fed_fbb_site, aes(x=x, ymin=conf.low, ymax=conf.high), alpha=0.25, colour="darkblue")+
  scale_fill_paletteer_d("nationalparkcolors::Acadia")+
  xlab("Site mean first bud burst date (1 = 1st Jan)")+ 
  ylab("First egg date (1 = 1st Jan)")+ 
  theme_bw()

#Plot the mean prediction and CIs with the data
fed_dev_fbb_plot <- ggplot(pred_fed_fbb_dev, aes(x,predicted))+ 
  geom_line(lwd=1.2, colour="blue")+ 
  geom_point(data=fed_best_window.cat.tree, aes(Annual_fbb_deviations, fed), colour="lightblue")+ 
  geom_ribbon(data=pred_fed_fbb_dev, aes(x=x, ymin=conf.low, ymax=conf.high), alpha=0.25, colour="blue")+
  scale_fill_paletteer_d("nationalparkcolors::Acadia")+
  xlab("Annual deviations from site mean first bud burst date")+ 
  ylab("First egg date (1 = 1st Jan)")+ 
  theme_bw()

fbb_plots <- fed_site_fbb_plot + fed_dev_fbb_plot
print(fbb_plots)

library(sjPlot)
library(lme4)

tab_model(fed_mod.cat.tree, show.stat = TRUE, show.df = TRUE)