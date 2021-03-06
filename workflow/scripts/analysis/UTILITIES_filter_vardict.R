return_vardict_output <- function(DIR_vardict) {

	df_main <- as.data.frame(suppress_messages((read_delim(DIR_vardict, delim = "\t")))) 
	df <- df_main %>% 
		mutate(Sample_name = gsub(".tsv", "", basename(DIR_vardict))) %>%
		filter(!str_detect(Alt, 'N')) 	# Drop variants if the called variant has an "N" in it. 

	return(df)

}

return_anno_output_vardict <- function(PATH_ANNOVAR) {

	df_scrap <- as.data.frame(read_delim(PATH_ANNOVAR, delim = "\t"))
	col_names_vector <- c(names(df_scrap)[1:118], "x1", "x2", "x3", "CHROM", "POS", "ID", "REF", "ALT", "QUAL", "FILTER", "INFO", "FORMAT", gsub(".hg38_multianno.txt", "", basename(PATH_ANNOVAR)))

	info_col_names <- c("SAMPLE", "TYPE", "DP", "VD", "AF", "BIAS", "REFBIAS", "VARBIAS", "PMEAN", "PSTD", "QUAL", "QSTD", "SBF", "ODDRATIO", "MQ", "SN", "HIAF", "ADJAF", "SHIFT3", "MSI", "MSILEN", "NM", "HICNT", "HICOV", "LSEQ", "RSEQ", "DUPRATE", "SPLITREAD", "SPANPAIR")
	format_col_names <- c("GT", "DP", "VD", "AD", "AF", "RD", "ALD")

	df_main <- read_delim(
					PATH_ANNOVAR, 
					delim = "\t", 
					col_names = col_names_vector) %>%
			   select(Chr, Start, Ref, Alt, Func.refGene, Gene.refGene, Func.knownGene, Gene.knownGene, AAChange.refGene, ExAC_ALL, FILTER, gnomAD_exome_ALL, INFO, gsub(".hg38_multianno.txt", "", basename(PATH_ANNOVAR))) %>%
				rename(
					FORMAT_values = gsub(".hg38_multianno.txt", "", 
					basename(PATH_ANNOVAR))) %>%
				separate(
					col = INFO, 
					sep = ";",	
					into = info_col_names, 
					remove = FALSE) %>%
				separate(
					col = FORMAT_values, 
					sep = ":",	
					into = format_col_names, 
					remove = FALSE) %>%
				mutate(across(info_col_names, gsub, pattern = ".*=", replacement = "")) %>%
				separate(col = RD, sep = ",", into = c("REF_Fw", "REF_Rv"), remove = TRUE) %>%
				separate(col = ALD, sep = ",", into = c("ALT_Fw", "ALT_Rv"), remove = TRUE) %>%
  			    select(SAMPLE, Chr, Start, Ref, Alt, AF, DP, VD, MQ, TYPE, FILTER, SBF, ODDRATIO, Func.refGene, Gene.refGene, Func.knownGene, Gene.knownGene, AAChange.refGene, ExAC_ALL, gnomAD_exome_ALL, REF_Fw, REF_Rv, ALT_Fw, ALT_Rv)

	names(df_main) <- c("Sample_name", "Chr", "Start", "Ref", "Alt", "VarFreq", "Reads1", "Reads2", "Mapping_quality", "variant", "FILTER", "StrandBias_Fisher_pVal", "StrandBias_OddsRatio", "Func.refGene", "Gene.refGene", "Func.knownGene", "Gene.knownGene", "AAChange.refGene", "ExAC_ALL", "gnomAD_exome_ALL", "REF_Fw", "REF_Rv", "ALT_Fw", "ALT_Rv")
	df_main$variant <- tolower(df_main$variant)

	return(df_main)

}

# do a merge based on column to combine metadata 
parse_anno_output <- function(DIR_ANNOVAR) {

	# determine which dir to scan based on the cariant_type given

	anno_df_list <- lapply(as.list(list.files(DIR_ANNOVAR, full.names = TRUE, pattern = "\\.hg38_multianno.txt$")), return_anno_output_vardict)
	anno_df <- as.data.frame(do.call(rbind, anno_df_list)) %>%
				mutate(Sample_name = gsub(".hg38_multianno.txt", "", Sample_name), 
						Start = as.character(Start)) 

	return(anno_df)

}

add_bg_error_rate <- function(variants_df, bg) {

	# modify the vars df
	variants_df <- variants_df %>% mutate(error_type = paste0("mean_error", variants_df$Ref, "to", variants_df$Alt))
	
	# add the deletions 
	idx <- which(variants_df$variant == "deletion")
	variants_df$error_type[idx] <- "mean_errordel"
	
	# add the insertions
	idx <- which(variants_df$variant == "insertion")
	variants_df$error_type[idx] <- "mean_errorins"

	# modify the bg error rate df
	# bg <- read_delim(PATH_bg, delim = "\t")
	bg$chrom <- paste0("chr", bg$chrom)
	bg <- gather(bg, "error_type", "error_rate", starts_with("mean_error"))

	# now if we have a deletion, we want to recover the pos + 1 in the bg file, this is actual place where deletion begins 
	var_pos <- variants_df$Start
	deletion_idx <- which(variants_df$variant == "deletion")
	
	if (length(deletion_idx) > 0) {
		var_pos[deletion_idx] <- as.numeric(var_pos[deletion_idx]) + 1 # add 1 to the position of all the deletions
		variants_df$Start <- var_pos}

	# this merge adds an exta col with the error rate 
	bg$pos <- as.character(bg$pos)
	variants_df <- left_join(variants_df, bg, by = c("Chr" = "chrom", "Start" = "pos", "error_type" = "error_type")) # to add the error rates from bg to variants df

	# subtract 1 from the positions after merging
	if (length(deletion_idx) > 0) {
		deletion_idx <- which(variants_df$variant == "deletion")
		variants_df$Start[deletion_idx] <- as.numeric(variants_df$Start[deletion_idx]) - 1}

	return(variants_df)
}

# main function to run everything
MAIN <- function(cohort_name,
					THRESHOLD_ExAC_ALL, 
					VALUE_Func_refGene, 
					THRESHOLD_VarFreq, 
					THRESHOLD_Reads2, 
					THRESHOLD_VAF_bg_ratio, 
					DIR_vardict, 
					DIR_ANNOVAR,
					bg,
					PATH_bets_somatic,
					PATH_bets_germline,
					PATH_panel_genes,
					PATH_bed,
					DIR_depth_metrics,
					PATH_collective_depth_metrics,
					DIR_finland_bams, 
					DIR_temp,
					DIR_tnvstats,
					PATH_filter_tnvstats_script, 
					variant_caller){

	variant_caller = variant_caller # just so the function doesn't complain about us not using this argument
	combined <- combine_anno_vardict(DIR_vardict, DIR_ANNOVAR) # add annovar annots to the varscan outputs
	combined <- add_patient_id(combined, cohort_name)
	combined <- add_bg_error_rate(combined, bg) # background error rate
	combined <- add_AAchange_effect(combined) # protein annot and the effects
	combined$Cohort_name <- cohort_name
	combined <- add_sample_type(combined)

	combined <- combined %>%
						mutate(Total_reads = Reads1 + Reads2, 
								VAF_bg_ratio = VarFreq/error_rate) %>%
						select(Sample_name, Sample_type, patient_id, Cohort_name, Chr, Start, Ref, Alt, VarFreq, Reads1, Reads2, StrandBias_Fisher_pVal, StrandBias_OddsRatio, REF_Fw, REF_Rv, ALT_Fw, ALT_Rv, Func.refGene, Gene.refGene, AAChange.refGene, Protein_annotation, Effects, ExAC_ALL, variant, error_rate, VAF_bg_ratio, Total_reads) %>%
						filter(ExAC_ALL <= THRESHOLD_ExAC_ALL, 
								Func.refGene != VALUE_Func_refGene,
								VAF_bg_ratio >= THRESHOLD_VAF_bg_ratio, # vaf should be at least 15 times more than the bg error rate
								StrandBias_Fisher_pVal > 0.05) 

	# a common naming convention i will be sticking to from now on
	names(combined) <- c("Sample_name", "Sample_type", "Patient_ID", "Cohort_name", "Chrom", "Position", "Ref", "Alt", "VAF", "Ref_reads", "Alt_reads", "StrandBias_Fisher_pVal", "StrandBias_OddsRatio", "REF_Fw", "REF_Rv", "ALT_Fw", "ALT_Rv", "Function", "Gene", "AAchange", "Protein_annotation", "Effects", "ExAC_ALL", "Variant", "Error_rate", "VAF_bg_ratio", "Total_reads")

	idx <- grep("splicing", combined$Function)
	combined$Effects[idx] <- "splicing"

	# add a new col indicating if the variant is duplicated or not
	combined <- identify_duplicates(combined)

	# now filtering based on vaf, read support and depth etc. 
	combined <- combined %>%
				filter((Total_reads >= 1000 & VAF >= 0.005) | 
						(Total_reads <= 1000 & Alt_reads >= 5), 
						VAF < THRESHOLD_VarFreq)

	combined <- subset_to_panel(PATH_bed, combined) # subset to panel
	combined <- add_depth(DIR_depth_metrics, PATH_collective_depth_metrics, combined) # add depth information at these positions 
	combined <- compare_with_bets(PATH_bets_somatic, PATH_bets_germline, PATH_panel_genes, combined) # adds three new columns

	# add an extra col for alerting the user if the variant isn't found, despite gene being in the bets
	combined <- combined %>% mutate(Status = case_when(
										(In_germline_bets == FALSE & In_panel == TRUE) ~ "ALERT", 
										(In_germline_bets == TRUE & In_panel == TRUE) ~ "Great",
										(In_germline_bets == TRUE & In_panel == FALSE) ~ "Error",
										TRUE ~ "OK"), 
								Position = as.numeric(Position))

	if (cohort_name == "new_chip_panel"){

		# add the sample ID from the finland bams
		finland_sample_IDs <- gsub(".bam", "", grep("*.bam$", list.files(DIR_finland_bams), value = TRUE))
		combined$Sample_name_finland <- unlist(lapply(as.list(gsub("GUBB", "GU", combined$Patient_ID)), function(x) grep(x, finland_sample_IDs, value = TRUE)))
		combined <- combined %>% relocate(Sample_name_finland, .after = Sample_name)

		# write_csv(combined, "/groups/wyattgrp/users/amunzur/pipeline/results/temp/vardict_combined.csv")
		# combined <- read_csv("/groups/wyattgrp/users/amunzur/pipeline/results/temp/vardict_combined.csv")

		message("Filtering tnvstats right now.")
		filtered_tnvstats <- filter_tnvstats_by_variants(
								variants_df = combined, 
								DIR_tnvstats = DIR_tnvstats, 
								PATH_temp = file.path(DIR_temp, variant_caller), 
								PATH_filter_tnvstats_script = PATH_filter_tnvstats_script, 
								identifier = variant_caller)

		combined <- add_finland_readcounts(combined, filtered_tnvstats, variant_caller)

	# Check for duplicated rows just before returning the object.
	combined <- check_duplicated_rows(combined, TRUE)

	}

	return(combined)

} # end of function

combine_and_save <- function(variants, PATH_validated_variants, PATH_SAVE_chip_variants){

	validated_vars <- compare_with_jacks_figure(PATH_validated_variants, variants)
	# variants$detected <- variants$Position %in% validated_vars$Position # add a new col to show if the same var was detected in jacks figure

	dir.create(dirname(PATH_validated_variants))
	dir.create(dirname(PATH_SAVE_chip_variants))

	# PATH_SAVE_chip_variants <- "/groups/wyattgrp/users/amunzur/chip_project/variant_lists/chip_variants.csv"
	write_csv(variants, PATH_SAVE_chip_variants) # snv + indel, csv
	write_delim(variants, gsub(".csv", ".tsv", PATH_SAVE_chip_variants), delim = "\t") # snv + indel, tsv

	write_csv(validated_vars, gsub("chip_variants.csv", "validated_variants.csv", PATH_SAVE_chip_variants)) # jack df as csv
	write_delim(validated_vars, gsub("chip_variants.csv", "validated_variants.tsv", PATH_SAVE_chip_variants), delim = "\t") # jack df as tsv
}