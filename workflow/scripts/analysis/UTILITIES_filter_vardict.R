return_vardict_output <- function(DIR_vardict) {

	df_main <- as.data.frame(read_delim(DIR_vardict, delim = "\t")) 
	df <- df_main %>% mutate(Sample_name = gsub(".tsv", "", basename(DIR_vardict)))

	return(df)

}

# do a merge based on column to combine metadata 
combine_anno_vardict <- function(DIR_vardict, DIR_ANNOVAR) {

	# determine which dir to scan based on the cariant_type given

	anno_df_list <- lapply(as.list(list.files(DIR_ANNOVAR, full.names = TRUE, pattern = "\\.hg38_multianno.txt$")), return_anno_output)
	anno_df <- as.data.frame(do.call(rbind, anno_df_list)) %>%
				mutate(Sample_name = gsub(".hg38_multianno.txt", "", Sample_name), 
						Start = as.character(Start)) 

	vardict_df_list <- lapply(as.list(list.files(DIR_vardict, full.names = TRUE, pattern = "\\.tsv$")), return_vardict_output)
	vardict_df <- do.call(rbind, vardict_df_list) %>%
				mutate(Start = as.character(Start)) 

	combined <- left_join(vardict_df, anno_df, by = c("Sample_name", "Chr", "Start")) %>%
					mutate(Ref = vardict_df$Ref, 
						Alt = vardict_df$Alt,
						ExAC_ALL = as.numeric(gsub("\\.", 0, ExAC_ALL)), 
						gnomAD_exome_ALL = as.numeric(gsub("\\.", 0, gnomAD_exome_ALL)))

	combined$Ref.x <- NULL
	combined$Alt.x <- NULL
	combined$Ref.y <- NULL
	combined$Alt.y <- NULL

	return(combined)

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
	original_pos <- variants_df$Start

	var_pos <- variants_df$Start
	deletion_idx <- which(variants_df$variant == "deletion")
	
	if (length(deletion_idx) > 0) {
		var_pos[deletion_idx] <- as.numeric(var_pos[deletion_idx]) + 1 # add 1 to the position of all the deletions
		variants_df$Start <- var_pos}

	bg <- subset(bg, pos %in% variants_df$Start) # subset to the positions we have in the variants so that the df is smaller and more managable

	# this merge adds an exta col with the error rate 
	bg$pos <- as.character(bg$pos)
	variants_df <- left_join(variants_df, bg, by = c("Start" = "pos", "error_type" = "error_type"))

	# the merge above adds two extra cols we dont want, remove those 
	variants_df$chrom <- NULL
	variants_df$ref <- NULL

	# subtract 1 from the positions after merging
	if (length(deletion_idx) > 0) {
		deletion_idx <- which(variants_df$variant == "deletion")
		variants_df$Start[deletion_idx] <- as.numeric(variants_df$Start[deletion_idx]) - 1}

	return(variants_df)
}

# main function to run everything
MAIN <- function(THRESHOLD_ExAC_ALL, 
					VALUE_Func_refGene, 
					THRESHOLD_VarFreq, 
					THRESHOLD_Reads2, 
					THRESHOLD_VAF_bg_ratio, 
					DIR_vardict, 
					DIR_ANNOVAR,
					bg,
					PATH_bets,
					PATH_bed,
					DIR_depth_metrics,
					DIR_finland_bams){

	combined <- combine_anno_vardict(DIR_vardict, DIR_ANNOVAR) # add annovar annots to the varscan outputs

	# add patient id
	x <- str_split(combined$Sample_name, "-") # split the sample name
	combined$patient_id <- paste(lapply(x, "[", 1), lapply(x, "[", 2), lapply(x, "[", 3), sep = "-") # paste 2nd and 3rd elements to create the sample name 

	combined <- add_bg_error_rate(combined, bg) # background error rate
	combined_not_intronic <- combined %>%
						mutate(Total_reads = Reads1 + Reads2, 
								VAF_bg_ratio = VarFreq/error_rate) %>%
						select(Sample_name, patient_id, Chr, Start, Ref, Alt, VarFreq, Reads1, Reads2, Func.refGene, Gene.refGene, AAChange.refGene, ExAC_ALL, variant, error_rate, VAF_bg_ratio, Total_reads) %>%
						filter(ExAC_ALL <= THRESHOLD_ExAC_ALL, 
								Func.refGene != VALUE_Func_refGene,
								VAF_bg_ratio >= THRESHOLD_VAF_bg_ratio) # vaf should be at least 15 times more than the bg error rate

	# a common naming convention i will be sticking to from now on
	names(combined_not_intronic) <- c("Sample_name", "Patient_ID", "Chrom", "Position", "Ref", "Alt", "VAF", "Ref_reads", "Alt_reads", "Function", "Gene", "AAchange", "ExAC_ALL", "Variant", "Error_rate", "VAF_bg_ratio", "Total_reads")

	dedup <- distinct(combined_not_intronic, Chrom, Position, Ref, Alt, .keep_all = TRUE) # remove duplicated variants

	# now filtering based on vaf, read support and depth etc. 
	dedup <- dedup %>%
				filter((Total_reads >= 1000 & VAF >= 0.005) | 
						(Total_reads <= 1000 & Alt_reads >= 5), 
						VAF < THRESHOLD_VarFreq)

	dedup <- subset_to_panel(PATH_bed, dedup) # subset to panel
	dedup <- add_depth(DIR_depth_metrics, dedup) # add depth information at these positions 
	dedup <- compare_with_bets(PATH_bets, dedup)

	# add an extra col for alerting the user if the variant isn't found, despite gene being in the bets
	dedup <- dedup %>% mutate(Status = case_when(
										(detected == FALSE & Gene_in_bets == TRUE) ~ "ALERT", 
										(detected == TRUE & Gene_in_bets == TRUE) ~ "Great",
										(detected == TRUE & Gene_in_bets == FALSE) ~ "Error",
										TRUE ~ "OK"))

	# add the sample ID from the finland bams
	finland_sample_IDs <- gsub(".bam", "", grep("*.bam$", list.files(DIR_finland_bams), value = TRUE))
	dedup$Sample_name_finland <- unlist(lapply(as.list(gsub("GUBB", "GU", dedup$Patient_ID)), function(x) grep(x, finland_sample_IDs, value = TRUE)))
	dedup <- dedup %>% relocate(Sample_name_finland, .after = Sample_name)

	return(dedup)

}

combine_and_save <- function(variants, PATH_validated_variants, PATH_SAVE_chip_variants){

	# make a separate df for igv because the indel positions need to be adjusted before we can take snapshots 
	idx <- which(variants$Variant == "deletion")
	if (length(idx) > 0) {
		variants_igv <- variants %>% mutate(Position = as.numeric(Position))
		variants_igv$Position[idx] <- variants_igv$Position[idx] + 1} else {variants_igv <- variants}

	validated_vars <- compare_with_jacks_figure(PATH_validated_variants, variants)
	# variants$detected <- variants$Position %in% validated_vars$Position # add a new col to show if the same var was detected in jacks figure

	# PATH_SAVE_chip_variants <- "/groups/wyattgrp/users/amunzur/chip_project/variant_lists/chip_variants.csv"
	write_csv(variants, PATH_SAVE_chip_variants) # snv + indel, csv
	write_delim(variants, gsub(".csv", ".tsv", PATH_SAVE_chip_variants), delim = "\t") # snv + indel, tsv
	write_delim(variants_igv, gsub("chip_variants.csv", "chip_variants_igv.tsv", PATH_SAVE_chip_variants), delim = "\t") # snv + indel for igv

	write_csv(validated_vars, gsub("chip_variants.csv", "validated_variants.csv", PATH_SAVE_chip_variants)) # jack df as csv
	write_delim(validated_vars, gsub("chip_variants.csv", "validated_variants.tsv", PATH_SAVE_chip_variants), delim = "\t") # jack df as tsv
}