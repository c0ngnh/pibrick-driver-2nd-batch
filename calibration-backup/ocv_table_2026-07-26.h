/*
 * Auto-calibrated OCV table for piBrick battery driver
 * Generated: 2026-07-26T18:00:28.405781
 * Source records: 3455
 * SOC coverage: 99.0%
 * Confidence: 1.00
 *
 * WARNING: Review and test before applying to production!
 */

#ifndef _BQ25890_BATTERY_OCV_CALIBRATED_H
#define _BQ25890_BATTERY_OCV_CALIBRATED_H

typedef struct {
    int voltage;  /* centivolts */
    int percentage;
} VoltageMap;

/* Calibrated voltage-to-SOC mapping */
static VoltageMap voltage_to_percent_table[] = {
	{ 324,   3 }, // 7 samples
	{ 324,   2 }, // 4 samples
	{ 325,   4 }, // 7 samples
	{ 326,   5 }, // 7 samples
	{ 326,   1 }, // 9 samples
	{ 327,   8 }, // 13 samples
	{ 327,   7 }, // 8 samples
	{ 327,   6 }, // 6 samples
	{ 328,   9 }, // 17 samples
	{ 330,  10 }, // 24 samples
	{ 330,   0 }, // 4 samples
	{ 332,  11 }, // 24 samples
	{ 334,  12 }, // 30 samples
	{ 335,  14 }, // 37 samples
	{ 335,  13 }, // 30 samples
	{ 336,  15 }, // 20 samples
	{ 339,  16 }, // 30 samples
	{ 341,  18 }, // 27 samples
	{ 342,  17 }, // 30 samples
	{ 343,  20 }, // 29 samples
	{ 343,  19 }, // 27 samples
	{ 344,  21 }, // 28 samples
	{ 345,  22 }, // 30 samples
	{ 346,  23 }, // 28 samples
	{ 347,  25 }, // 29 samples
	{ 347,  24 }, // 29 samples
	{ 348,  27 }, // 29 samples
	{ 348,  26 }, // 29 samples
	{ 349,  28 }, // 28 samples
	{ 350,  29 }, // 29 samples
	{ 351,  32 }, // 19 samples
	{ 351,  31 }, // 28 samples
	{ 351,  30 }, // 29 samples
	{ 354,  36 }, // 34 samples
	{ 355,  37 }, // 28 samples
	{ 355,  35 }, // 36 samples
	{ 355,  33 }, // 33 samples
	{ 356,  47 }, // 18 samples
	{ 356,  45 }, // 26 samples
	{ 356,  34 }, // 33 samples
	{ 357,  46 }, // 27 samples
	{ 357,  44 }, // 22 samples
	{ 357,  39 }, // 31 samples
	{ 357,  38 }, // 28 samples
	{ 358,  40 }, // 28 samples
	{ 359,  49 }, // 24 samples
	{ 359,  48 }, // 28 samples
	{ 359,  42 }, // 31 samples
	{ 359,  41 }, // 29 samples
	{ 360,  51 }, // 17 samples
	{ 360,  50 }, // 26 samples
	{ 360,  43 }, // 27 samples
	{ 366,  52 }, // 37 samples
	{ 367,  56 }, // 41 samples
	{ 367,  54 }, // 33 samples
	{ 367,  53 }, // 40 samples
	{ 368,  58 }, // 46 samples
	{ 368,  57 }, // 50 samples
	{ 368,  55 }, // 39 samples
	{ 369,  59 }, // 46 samples
	{ 370,  60 }, // 44 samples
	{ 372,  61 }, // 46 samples
	{ 373,  62 }, // 44 samples
	{ 377,  63 }, // 47 samples
	{ 378,  64 }, // 64 samples
	{ 379,  65 }, // 66 samples
	{ 381,  67 }, // 73 samples
	{ 381,  66 }, // 85 samples
	{ 382,  71 }, // 83 samples
	{ 382,  68 }, // 66 samples
	{ 383,  73 }, // 51 samples
	{ 383,  72 }, // 75 samples
	{ 383,  70 }, // 75 samples
	{ 383,  69 }, // 69 samples
	{ 384,  74 }, // 65 samples
	{ 384,  91 }, // 8 samples
	{ 385,  75 }, // 72 samples
	{ 385,  92 }, // 8 samples
	{ 386,  83 }, // 21 samples
	{ 386,  77 }, // 69 samples
	{ 386,  76 }, // 71 samples
	{ 387,  78 }, // 77 samples
	{ 387,  89 }, // 21 samples
	{ 387,  88 }, // 27 samples
	{ 388,  93 }, // 9 samples
	{ 389,  79 }, // 89 samples
	{ 390,  81 }, // 96 samples
	{ 390,  80 }, // 79 samples
	{ 390,  90 }, // 20 samples
	{ 390,  82 }, // 34 samples
	{ 390,  94 }, // 8 samples
	{ 391,  87 }, // 31 samples
	{ 391,  86 }, // 28 samples
	{ 393,  85 }, // 36 samples
	{ 394,  84 }, // 27 samples
	{ 395,  95 }, // 9 samples
	{ 399,  99 }, // 36 samples
	{ 400,  96 }, // 13 samples
	{ 401,  98 }, // 14 samples
	{ 401,  97 }, // 16 samples
};
const int table_size = ARRAY_SIZE(voltage_to_percent_table);

#endif /* _BQ25890_BATTERY_OCV_CALIBRATED_H */