#!/usr/bin/env python3
"""
=============================================================================
 Pipeline de Treinamento ML — XGBoost Survival AFT
 Modela MFE continuo com censura intervalar (Accelerated Failure Time)
 Um unico modelo serve qualquer threshold de R (2R, 3R, etc.)
 Validacao: Walk-Forward temporal (sem random split)
 Exportacao: MQL5 (.mqh) com MathExp(score) para predicted_mfe
=============================================================================

Uso:
  python train_AFT_model.py
  python train_AFT_model.py --dataset caminho/dataset.csv --optuna-trials 60
  python train_AFT_model.py --export-mql --skip-shap

Requisitos:
  pip install numpy pandas scikit-learn xgboost matplotlib optuna shap
"""
from __future__ import annotations

import argparse
import json
import math
import os
import sys
import time
import traceback
import tempfile
import warnings
from dataclasses import dataclass, field
from datetime import datetime
from pathlib import Path
from typing import Any, Dict, List, Optional, Tuple

warnings.filterwarnings("ignore", category=UserWarning)
warnings.filterwarnings("ignore", category=FutureWarning)

# ---------------------------------------------------------------------------
# Dependency checks
# ---------------------------------------------------------------------------
REQUIRED_PKGS = ["numpy", "pandas", "sklearn", "xgboost", "matplotlib"]


def ensure_dependencies() -> None:
    missing = []
    for pkg in REQUIRED_PKGS:
        try:
            __import__(pkg)
        except ImportError:
            missing.append(pkg)
    if missing:
        raise SystemExit(
            f"Dependencias ausentes: {', '.join(missing)}\n"
            f"Instale com:\n  python -m pip install {' '.join(missing)}\n"
            "Opcional:\n  python -m pip install optuna shap\n"
        )


ensure_dependencies()

try:
    import optuna
    optuna.logging.set_verbosity(optuna.logging.WARNING)
    HAS_OPTUNA = True
except ImportError:
    HAS_OPTUNA = False

try:
    import shap
    HAS_SHAP = True
except ImportError:
    HAS_SHAP = False

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
import numpy as np
import pandas as pd
import xgboost as xgb
from sklearn.inspection import permutation_importance
from sklearn.metrics import (
    average_precision_score,
    confusion_matrix,
    f1_score,
    precision_score,
    recall_score,
    roc_auc_score,
)

# ===========================================================================
# CONFIGURACAO GLOBAL
# ===========================================================================

# 42 features do padrao POI SMC (-1 atr bruto, +2 m1_pattern_velocity e m1_bias_aligned_with_m5)
FEATURE_COLUMNS: List[str] = [
    "confirm_age_minutes", "range_atr_ratio",
    "dist_to_favorable_liquidity", "dist_to_adverse_liquidity", "dist_to_last_bos", "pd_entry_zone",
    "pd_zone_mid_distance_from_eq", "pd_is_favorable_for_bias", "range_pos", "velocity", "alignment",
    "atr5_atr20_ratio", "dist_to_prev_day_high", "dist_to_prev_day_low",
    "pattern_total_range_atr", "leg_ab_atr", "leg_bc_atr", "leg_cd_atr", "leg_de_atr", "leg_ef_atr",
    "bc_retracement_of_ab", "de_retracement_of_cd", "ef_extension_vs_de",
    "confirm_displacement_atr", "zone_size_vs_pattern_range",
    "path_efficiency", "e_candle_range_atr", "e_rejection_wick_atr", "bars_a_to_f_m1",
    "sweep_depth_beyond_c_atr", "sweep_depth_beyond_c_ratio", "f_break_margin_vs_d_atr",
    "confirm_to_touch_max_extension_atr", "confirm_to_touch_pullback_efficiency",
    "poi_overlaps_m5_ob", "dist_to_nearest_m5_ob_atr", "poi_overlaps_fvg", "dist_to_nearest_fvg_atr",
    "real_volume_e_atr_norm", "real_volume_f_atr_norm",
    "m1_pattern_velocity", "m1_bias_aligned_with_m5"
]

# Avaliacao multi-R: R targets para avaliar com o mesmo modelo
# Threshold selection testa todos os R targets e escolhe o par (R, mfe_thr) que maximiza E[R]/ano
EVAL_R_TARGETS = [2.0, 3.0, 4.0, 5.0]
PRIMARY_R_TARGET = 3.0  # fallback se multi-R nao convergir
R_NEG = -1.0

# Epsilon para log(MFE) — evita log(0)
MFE_EPSILON = 0.01

DATASET_DEFAULT = r"C:\Users\fe461\AppData\Roaming\MetaQuotes\Terminal\Common\Files\NOVOML\dataset_poi_standalone.csv"
SESSION_START = "09:00"
SESSION_END = "17:00"  # exclui entradas com <1h de janela antes do horario de zeragem (18h)

# Split temporal
TEST_RATIO = 0.15
CALIB_RATIO = 0.00   # AFT nao precisa de calibracao
THRESH_RATIO = 0.15  # Mais dados para threshold selection
EMBARGO_DAYS = 1

# Walk-forward
WF_FOLDS = 5
WF_VALID_RATIO = 0.12
EARLY_STOP_RATIO = 0.12
MIN_WF_TRAIN_DAYS = 60
MIN_WF_VALID_DAYS = 10
MIN_EARLY_STOP_DAYS = 10

# Threshold selection (MFE threshold)
MIN_THRESHOLD_TRADES = 20
TRADING_DAYS_PER_YEAR = 252
TARGET_TRADES_PER_YEAR_MIN = 100
TARGET_TRADES_PER_YEAR_MAX = 600 # Mudei para 600 para dar flexibilidade ao POI

# MFE threshold grid: Nota de expectativa preditiva do modelo
# (Uma prev de 1.2 geralmente é um trade excelente buscando alvo de 3R)
MFE_THRESHOLD_MIN = 0.8
MFE_THRESHOLD_MAX = 4.0
MFE_THRESHOLD_STEPS = 101

# Misc
TOP_IMPORTANCE = 25
RANDOM_SEED = 42
PERM_REPEATS = 5
SHAP_MAX_SAMPLES = 500


# ===========================================================================
# DATA STRUCTURES
# ===========================================================================


@dataclass
class FinalSplit:
    """Split temporal: train -> threshold -> test (sem calib — AFT nao calibra)"""
    train_idx: pd.Index
    thr_idx: pd.Index
    test_idx: pd.Index


@dataclass
class Fold:
    """Walk-forward fold"""
    train_idx: pd.Index
    early_stop_idx: pd.Index
    valid_idx: pd.Index


@dataclass
class TrainResult:
    """Resultado completo do modelo AFT"""
    model_name: str
    booster: xgb.Booster
    params: Dict[str, Any]
    mfe_threshold: float
    thr_metrics: Dict[str, Any]
    test_metrics: Dict[str, Any]
    test_predicted_mfe: np.ndarray
    tuning_report: Dict[str, Any]
    fi_model: pd.DataFrame
    fi_perm: pd.DataFrame
    threshold_sweep: pd.DataFrame
    train_time_sec: float
    multi_r_results: Dict[float, Dict[str, Any]]


from sklearn.base import BaseEstimator

class AFTBoosterWrapper(BaseEstimator):
    """Wrapper para usar xgb.Booster com sklearn permutation_importance"""

    def __init__(self, booster: xgb.Booster = None, feature_names: List[str] = None,
                 best_iteration: int = 0):
        self.booster = booster
        self.feature_names = feature_names
        self.best_iteration = best_iteration

    def predict(self, X: Any) -> np.ndarray:
        dmat = xgb.DMatrix(X, feature_names=self.feature_names)
        # survival:aft já aplica exp() internamente (PredTransform) — NÃO duplicar
        raw = self.booster.predict(
            dmat, iteration_range=(0, self.best_iteration + 1)
        )
        return np.clip(raw, MFE_EPSILON, 100.0)

    def fit(self, X: Any, y: Any) -> "AFTBoosterWrapper":
        return self


# ===========================================================================
# METRICAS E AVALIACAO
# ===========================================================================


def expected_r(y_true: np.ndarray, take: np.ndarray, r_pos: float) -> float:
    """E[R] por trade selecionado"""
    if take.sum() == 0:
        return float("-inf")
    wins = ((y_true == 1) & take).sum()
    losses = ((y_true == 0) & take).sum()
    return (wins * r_pos + losses * R_NEG) / take.sum()


def profit_factor(y_true: np.ndarray, take: np.ndarray, r_pos: float) -> float:
    """Profit factor = gross_wins / gross_losses"""
    if take.sum() == 0:
        return 0.0
    wins = ((y_true == 1) & take).sum() * r_pos
    losses = ((y_true == 0) & take).sum() * abs(R_NEG)
    if losses == 0:
        return float("inf") if wins > 0 else 0.0
    return wins / losses


def trade_frequency(take: np.ndarray, day_count: int) -> Dict[str, float]:
    trades = int(take.sum())
    safe_days = max(1, int(day_count))
    trades_per_day = trades / safe_days
    trades_per_year = trades_per_day * TRADING_DAYS_PER_YEAR
    return {
        "trade_count": trades,
        "day_count": safe_days,
        "trades_per_day": float(trades_per_day),
        "trades_per_year": float(trades_per_year),
    }


def evaluate_aft(y_true: np.ndarray, predicted_mfe: np.ndarray,
                 mfe_threshold: float, r_target: float,
                 day_count: int) -> Dict[str, float]:
    """Metricas completas para um MFE threshold e R target"""
    take = predicted_mfe >= mfe_threshold
    freq = trade_frequency(take, day_count)
    exp_r_trade = expected_r(y_true, take, r_target)
    pf = profit_factor(y_true, take, r_target)

    # Confusion matrix
    pred_binary = take.astype(int)
    if len(np.unique(y_true)) > 1 and len(np.unique(pred_binary)) > 1:
        tn, fp, fn, tp = confusion_matrix(y_true, pred_binary, labels=[0, 1]).ravel()
    else:
        tn = fp = fn = tp = 0
        if take.sum() == 0:
            tn = int((y_true == 0).sum())
            fn = int((y_true == 1).sum())
        elif take.all():
            tp = int((y_true == 1).sum())
            fp = int((y_true == 0).sum())

    # Win rate dos trades selecionados
    if take.sum() > 0:
        win_rate = ((y_true == 1) & take).sum() / take.sum()
    else:
        win_rate = 0.0

    # ROC-AUC e PR-AUC usando predicted_mfe como score
    if len(np.unique(y_true)) > 1:
        roc_auc = roc_auc_score(y_true, predicted_mfe)
        pr_auc = average_precision_score(y_true, predicted_mfe)
    else:
        roc_auc = 0.5
        pr_auc = 0.0

    return {
        "roc_auc": roc_auc,
        "pr_auc": pr_auc,
        "precision": precision_score(y_true, pred_binary, zero_division=0),
        "recall": recall_score(y_true, pred_binary, zero_division=0),
        "f1": f1_score(y_true, pred_binary, zero_division=0),
        "win_rate": float(win_rate),
        "trade_rate": float(take.mean()),
        "expected_r_per_trade": exp_r_trade,
        "expected_r_per_year": (
            exp_r_trade * freq["trades_per_year"]
            if np.isfinite(exp_r_trade) else float("-inf")
        ),
        "profit_factor": pf,
        "mfe_threshold": float(mfe_threshold),
        "r_target": float(r_target),
        **freq,
        "tp": int(tp), "fp": int(fp), "tn": int(tn), "fn": int(fn),
    }


def build_mfe_threshold_grid(y_true: np.ndarray, predicted_mfe: np.ndarray,
                             r_target: float, day_count: int) -> pd.DataFrame:
    """Grid de MFE thresholds para selecao"""
    rows = []
    for thr in np.linspace(MFE_THRESHOLD_MIN, MFE_THRESHOLD_MAX, MFE_THRESHOLD_STEPS):
        metrics = evaluate_aft(y_true, predicted_mfe, float(thr), r_target, day_count)
        in_band = (TARGET_TRADES_PER_YEAR_MIN <= metrics["trades_per_year"]
                   <= TARGET_TRADES_PER_YEAR_MAX)
        if metrics["trades_per_year"] < TARGET_TRADES_PER_YEAR_MIN:
            distance = TARGET_TRADES_PER_YEAR_MIN - metrics["trades_per_year"]
        elif metrics["trades_per_year"] > TARGET_TRADES_PER_YEAR_MAX:
            distance = metrics["trades_per_year"] - TARGET_TRADES_PER_YEAR_MAX
        else:
            distance = 0.0
        rows.append({
            "mfe_threshold": float(thr),
            "in_target_band": int(in_band),
            "distance_to_target_band": float(distance),
            **metrics,
        })
    return pd.DataFrame(rows)


def choose_mfe_threshold(y_true: np.ndarray, predicted_mfe: np.ndarray,
                         r_target: float, day_count: int
                         ) -> Tuple[float, Dict[str, float], pd.DataFrame]:
    """Seleciona MFE threshold otimo: maximiza E[R]/year dentro da banda"""
    grid = build_mfe_threshold_grid(y_true, predicted_mfe, r_target, day_count)
    eligible = grid[grid["trade_count"] >= MIN_THRESHOLD_TRADES].copy()

    if eligible.empty:
        # Fallback: Threshold menor possivel (provavelmente o que tera mais trades)
        fallback = grid.iloc[0]
        return float(fallback["mfe_threshold"]), fallback.to_dict(), grid

    # Prioridade: dentro da banda de trades/ano
    in_band = eligible[eligible["in_target_band"] == 1].copy()
    if not in_band.empty:
        selected = in_band.sort_values(
            ["expected_r_per_year", "expected_r_per_trade", "precision", "pr_auc"],
            ascending=[False, False, False, False],
        ).iloc[0]
        return float(selected["mfe_threshold"]), selected.to_dict(), grid

    # Fallback: mais proximo da banda
    selected = eligible.sort_values(
        ["distance_to_target_band", "expected_r_per_year", "expected_r_per_trade"],
        ascending=[True, False, False],
    ).iloc[0]
    return float(selected["mfe_threshold"]), selected.to_dict(), grid


def choose_best_r_and_threshold(df: pd.DataFrame, idx: pd.Index,
                                predicted_mfe: np.ndarray,
                                day_count: int
                                ) -> Tuple[float, float, Dict[str, float], pd.DataFrame]:
    """Testa todos EVAL_R_TARGETS e escolhe o par (R, mfe_threshold) que maximiza E[R]/ano.
    Retorna: (best_r, best_mfe_thr, best_metrics, best_grid)"""
    best_r = PRIMARY_R_TARGET
    best_thr = 2.0
    best_metrics: Dict[str, float] = {}
    best_grid = pd.DataFrame()
    best_score = float("-inf")

    for r in EVAL_R_TARGETS:
        col = f"hit_{int(r)}R" if r == int(r) else f"hit_{r:.1f}R"
        # Fallback: se nao tem a coluna hit exata, usa MFE >= r como label
        if col in df.columns:
            y_eval = df.loc[idx, col].values.astype(int)
        else:
            y_eval = (df.loc[idx, "mfe"].values >= r).astype(int)

        mfe_thr, metrics, grid = choose_mfe_threshold(y_eval, predicted_mfe, r, day_count)
        er_year = metrics.get("expected_r_per_year", float("-inf"))

        if not best_metrics or (np.isfinite(er_year) and er_year > best_score):
            best_score = er_year
            best_r = r
            best_thr = mfe_thr
            best_metrics = metrics
            best_grid = grid

    if best_score == float("-inf"):
        print(f"  [AVISO] Nenhum R target gerou trades validos com R>0. Fallback para default.")

    print(f"  [MULTI-R] Melhor: R={best_r:.1f} | thr={best_thr:.4f} | "
          f"E[R]/ano={best_metrics.get('expected_r_per_year', 0):.2f}")
    return best_r, best_thr, best_metrics, best_grid


def concordance_index_simple(predicted_mfe: np.ndarray,
                             actual_mfe: np.ndarray,
                             censored: np.ndarray) -> float:
    """C-index simplificado: correlacao de ranking em pares comparaveis"""
    n = len(predicted_mfe)
    concordant = 0
    discordant = 0
    tied = 0
    comparable = 0

    # Amostragem para performance (O(n^2) completo seria lento)
    if n > 2000:
        rng = np.random.RandomState(RANDOM_SEED)
        idx = rng.choice(n, size=2000, replace=False)
        predicted_mfe = predicted_mfe[idx]
        actual_mfe = actual_mfe[idx]
        censored = censored[idx]
        n = 2000

    for i in range(n):
        for j in range(i + 1, n):
            # So comparar se pelo menos um nao e censurado
            if censored[i] and censored[j]:
                continue
            # So comparar se os outcomes reais diferem
            if actual_mfe[i] == actual_mfe[j]:
                continue
            # Se i tem MFE menor (e nao censurado), ou j tem MFE menor (e nao censurado)
            if actual_mfe[i] < actual_mfe[j]:
                if censored[i]:
                    continue  # nao sabemos se i teria MFE maior
                comparable += 1
                if predicted_mfe[i] < predicted_mfe[j]:
                    concordant += 1
                elif predicted_mfe[i] > predicted_mfe[j]:
                    discordant += 1
                else:
                    tied += 1
            else:
                if censored[j]:
                    continue
                comparable += 1
                if predicted_mfe[j] < predicted_mfe[i]:
                    concordant += 1
                elif predicted_mfe[j] > predicted_mfe[i]:
                    discordant += 1
                else:
                    tied += 1

    if comparable == 0:
        return 0.5
    return (concordant + 0.5 * tied) / comparable


# ===========================================================================
# DATASET / SPLIT / WALK-FORWARD
# ===========================================================================


def load_dataset(path: Path) -> pd.DataFrame:
    """Carrega dataset e computa bounds AFT (y_lower, y_upper)"""
    if not path.exists():
        raise FileNotFoundError(f"Dataset nao encontrado: {path}")

    df = pd.read_csv(path)
    print(f"  [DATA] Linhas brutas: {len(df)}")

    # Filtro: Remover trades originados de POIs abandonados (> 5 dias)
    before_filter = len(df)
    if "confirm_age_minutes" in df.columns:
        df = df[df["confirm_age_minutes"] <= 7200].copy()
        if len(df) < before_filter:
            print(f"  [DATA] Ignorando {before_filter - len(df)} amostras super velhas (confirm_age_minutes > 5 dias)")

    # Verificar features que devem vir obrigatoriamente do CSV
    missing = [c for c in FEATURE_COLUMNS if c not in df.columns]
    if missing:
        raise ValueError(f"Features ausentes no CSV: {missing}")

    # Verificar colunas obrigatorias para AFT
    for col in ["mfe", "end_reason", "censored"]:
        if col not in df.columns:
            raise ValueError(f"Coluna '{col}' necessaria para AFT nao encontrada")

    # Verificar colunas de hit para avaliacao multi-R (obrigatorias: 1R, 2R, 3R do dataset)
    for r in [1.0, 2.0, 3.0]:
        col = f"hit_{int(r)}R"
        if col not in df.columns:
            raise ValueError(f"Coluna '{col}' necessaria para avaliacao em R={r}")
    # R targets sem coluna dedicada (1.5, 4.0, 5.0) usam mfe >= r como fallback

    # Parse entry_time
    df["entry_time"] = pd.to_datetime(
        df["entry_time"], format="%Y.%m.%d %H:%M", errors="coerce"
    )
    if df["entry_time"].isna().any():
        bad = df["entry_time"].isna().sum()
        print(f"  [WARN] {bad} linhas com entry_time invalido removidas")
        df = df.dropna(subset=["entry_time"])

    df = df.sort_values(["entry_time", "id"]).reset_index(drop=True)
    df["trade_date"] = df["entry_time"].dt.date
    df["trade_time"] = df["entry_time"].dt.time

    # [PESO] Calcular sample_weight para recencia (2025-2026)
    RECENCY_WEIGHT = 2.0
    df["sample_weight"] = 1.0
    mask_recent = df["entry_time"].dt.year >= 2025
    df.loc[mask_recent, "sample_weight"] = RECENCY_WEIGHT
    print(f"  [PESO] Recencia 2025+ ativada (peso {RECENCY_WEIGHT}): {mask_recent.sum()} trades")

    # Filtro de sessao B3
    ini = pd.to_datetime(SESSION_START).time()
    fim = pd.to_datetime(SESSION_END).time()
    before = len(df)
    df = df[(df["trade_time"] >= ini) & (df["trade_time"] <= fim)].copy()
    print(f"  [DATA] Filtro sessao {SESSION_START}-{SESSION_END}: {before} -> {len(df)}")

    # (filtro ob_size removido — dataset POI nao tem ob_size_atr)

    # --- Computar bounds AFT ---
    # end_reason: 0=SL, 1=MaxR, 2=session_end, 3=max_bars
    #
    # Decisao de modelagem para day trading (B3):
    #   end_reason=0 (SL)              → observacao EXATA: sabemos que MFE foi esse valor
    #   end_reason=1 (MaxR cap)        → RIGHT-CENSORED: sabemos MFE >= MaxR, mas poderia ser maior
    #   end_reason=2 (session end):
    #     - MFE >= SESSION_CENSOR_MFE  → RIGHT-CENSORED (trade estava indo bem, potencial > observado)
    #     - MFE <  SESSION_CENSOR_MFE  → EXATO (trade fraco, sessao so confirmou o que ja era)
    #   end_reason=3 (max_bars)        → observacao EXATA: janela de observacao expirou
    SESSION_CENSOR_MFE = 1.0  # threshold para considerar trade promissor no session_end
    df["y_lower"] = df["mfe"].clip(lower=MFE_EPSILON)
    df["y_upper"] = df["mfe"].clip(lower=MFE_EPSILON)

    maxr_mask = df["end_reason"] == 1
    session_promising_mask = (df["end_reason"] == 2) & (df["mfe"] >= SESSION_CENSOR_MFE)
    censored_mask = maxr_mask | session_promising_mask
    df.loc[censored_mask, "y_upper"] = 1e10  # +inf pratico

    n_exact = int((~censored_mask).sum())
    n_censored_total = int(censored_mask.sum())
    n_censored_maxr = int(maxr_mask.sum())
    n_censored_session = int(session_promising_mask.sum())
    n_session = int((df["end_reason"] == 2).sum())
    n_session_exact = n_session - n_censored_session
    n_maxbars = int((df["end_reason"] == 3).sum())
    n_sl = int((df["end_reason"] == 0).sum())
    print(f"  [AFT] Bounds: {n_exact} exatos "
          f"(SL={n_sl}, session_exato={n_session_exact}, maxbars={n_maxbars})"
          f" | {n_censored_total} censurados "
          f"(MaxR={n_censored_maxr}, session_promissor={n_censored_session}, thr={SESSION_CENSOR_MFE}R)")

    # Limpa inf/nan nas features
    df = df.replace([np.inf, -np.inf], np.nan)
    required_cols = FEATURE_COLUMNS + ["entry_time", "trade_date", "id",
                                        "mfe", "y_lower", "y_upper",
                                        "censored", "end_reason"]
    before = len(df)
    df = df.dropna(subset=required_cols).copy()
    if len(df) < before:
        print(f"  [DATA] Drop NaN: {before} -> {len(df)}")

    # [LOG1P] Volume real em escala bruta (50-14.000) — normalizar para nao dominar splits
    for _vcol in ["real_volume_e_atr_norm", "real_volume_f_atr_norm"]:
        if _vcol in df.columns:
            df[_vcol] = np.log1p(df[_vcol])
    print("  [DATA] log1p aplicado em real_volume_e_atr_norm e real_volume_f_atr_norm")


    # Estatisticas
    print(f"  [DATA] Final: {len(df)} amostras")
    print(f"  [DATA] MFE: mean={df['mfe'].mean():.3f} | "
          f"median={df['mfe'].median():.3f} | "
          f"std={df['mfe'].std():.3f}")
    for r in EVAL_R_TARGETS:
        col = f"hit_{int(r)}R" if r == int(r) else None
        r_label = f"{int(r)}R" if r == int(r) else f"{r:.1f}R"
        if col and col in df.columns:
            hit = int(df[col].sum())
        else:
            hit = int((df["mfe"] >= r).sum())
        print(f"  [DATA] hit_{r_label}: {hit} ({100*hit/len(df):.1f}%)")

    n_days = df["trade_date"].nunique()
    print(f"  [DATA] Dias unicos: {n_days} | "
          f"Periodo: {df['trade_date'].min()} a {df['trade_date'].max()}")

    return df.reset_index(drop=True)


def build_final_split(df: pd.DataFrame) -> FinalSplit:
    """Split temporal: train | embargo | threshold | embargo | test"""
    days = pd.Index(sorted(df["trade_date"].unique()))
    n = len(days)

    n_test = max(1, int(math.ceil(n * TEST_RATIO)))
    n_thr = max(1, int(math.ceil(n * THRESH_RATIO)))

    test_start = n - n_test
    thr_end = test_start - EMBARGO_DAYS
    thr_start = thr_end - n_thr
    train_end = thr_start - EMBARGO_DAYS

    if train_end < MIN_WF_TRAIN_DAYS:
        raise ValueError(
            f"Poucos dias para split robusto: train_end={train_end}, min={MIN_WF_TRAIN_DAYS}"
        )

    train_days = days[:train_end]
    thr_days = days[thr_start:thr_end]
    test_days = days[test_start:]

    split = FinalSplit(
        train_idx=df.index[df["trade_date"].isin(train_days)],
        thr_idx=df.index[df["trade_date"].isin(thr_days)],
        test_idx=df.index[df["trade_date"].isin(test_days)],
    )

    print(f"  [SPLIT] Train: {len(split.train_idx)} ({len(train_days)}d) "
          f"| Threshold: {len(split.thr_idx)} ({len(thr_days)}d) "
          f"| Test: {len(split.test_idx)} ({len(test_days)}d)")

    return split


def build_walk_forward_folds(df: pd.DataFrame, split: FinalSplit) -> List[Fold]:
    """Walk-forward expanding window folds dentro do periodo de treino"""
    train_days = pd.Index(sorted(df.loc[split.train_idx, "trade_date"].unique()))
    n = len(train_days)
    valid_len = max(MIN_WF_VALID_DAYS, int(math.ceil(n * WF_VALID_RATIO)))
    latest_train_end = n - valid_len - EMBARGO_DAYS
    min_end = MIN_WF_TRAIN_DAYS + MIN_EARLY_STOP_DAYS

    if latest_train_end < min_end:
        raise ValueError(f"Poucos dias para walk-forward: latest_train_end={latest_train_end} (min={min_end})")

    ends = np.linspace(min_end, latest_train_end, num=WF_FOLDS, dtype=int)
    folds: List[Fold] = []
    used = set()

    for end in ends:
        end = int(end)
        if end in used:
            continue
        used.add(end)

        tr_days = train_days[:end]
        es_len = max(MIN_EARLY_STOP_DAYS, int(math.ceil(len(tr_days) * EARLY_STOP_RATIO)))
        es_start = max(MIN_WF_TRAIN_DAYS, len(tr_days) - es_len)
        core_train_days = tr_days[:es_start]
        es_days = tr_days[es_start:]

        if len(core_train_days) < MIN_WF_TRAIN_DAYS or len(es_days) < MIN_EARLY_STOP_DAYS:
            continue

        valid_start = end + EMBARGO_DAYS
        valid_end = min(valid_start + valid_len, n)
        va_days = train_days[valid_start:valid_end]
        if len(va_days) < MIN_WF_VALID_DAYS:
            continue

        folds.append(Fold(
            train_idx=df.index[df["trade_date"].isin(core_train_days)],
            early_stop_idx=df.index[df["trade_date"].isin(es_days)],
            valid_idx=df.index[df["trade_date"].isin(va_days)],
        ))

    if not folds:
        raise ValueError("Nao foi possivel montar folds walk-forward")

    print(f"  [WF] {len(folds)} folds criados")
    for i, f in enumerate(folds):
        print(f"       Fold {i+1}: train={len(f.train_idx)} | "
              f"es={len(f.early_stop_idx)} | valid={len(f.valid_idx)}")

    return folds


def build_early_stop_split(df: pd.DataFrame, idx: pd.Index
                           ) -> Tuple[pd.Index, pd.Index]:
    """Separa os ultimos dias do treino para early stopping"""
    days = pd.Index(sorted(df.loc[idx, "trade_date"].unique()))
    if len(days) < (MIN_WF_TRAIN_DAYS + MIN_EARLY_STOP_DAYS):
        raise ValueError("Poucos dias para separar early stopping")

    es_len = max(
        MIN_EARLY_STOP_DAYS,
        int(math.ceil(len(days) * EARLY_STOP_RATIO)),
    )
    es_len = min(es_len, max(MIN_EARLY_STOP_DAYS, len(days) - MIN_WF_TRAIN_DAYS))
    split_point = len(days) - es_len

    train_days = days[:split_point]
    es_days = days[split_point:]

    if len(train_days) < MIN_WF_TRAIN_DAYS or len(es_days) < MIN_EARLY_STOP_DAYS:
        raise ValueError("Split de early stopping invalido")

    return (
        df.index[df["trade_date"].isin(train_days)],
        df.index[df["trade_date"].isin(es_days)],
    )


# ===========================================================================
# AFT MODEL BUILDING & TRAINING
# ===========================================================================


def make_dmatrix(df: pd.DataFrame, idx: pd.Index) -> xgb.DMatrix:
    """Cria DMatrix com bounds AFT e pesos a partir do dataframe"""
    X = df.loc[idx, FEATURE_COLUMNS]
    y_lower = df.loc[idx, "y_lower"].values
    y_upper = df.loc[idx, "y_upper"].values
    weights = df.loc[idx, "sample_weight"].values

    dmat = xgb.DMatrix(X, weight=weights, feature_names=FEATURE_COLUMNS)
    dmat.set_float_info("label_lower_bound", y_lower)
    dmat.set_float_info("label_upper_bound", y_upper)
    return dmat


def default_aft_params() -> Dict[str, Any]:
    """Hiperparametros default para AFT"""
    return dict(
        n_estimators=3000,  # alto fixo — early stopping decide quando parar
        max_depth=4,
        learning_rate=0.025,
        subsample=0.80,
        colsample_bytree=0.75,
        reg_alpha=0.15,
        reg_lambda=2.0,
        min_child_weight=5.0,
        gamma=0.08,
        aft_loss_distribution="normal",
        aft_loss_distribution_scale=1.2,
    )


def suggest_aft_params(trial: "optuna.Trial") -> Dict[str, Any]:
    """Espaco de busca Optuna para AFT"""
    # n_estimators NAO esta aqui: early_stopping_rounds ja controla quantas
    # arvores usar. Deixar o Optuna tunar n_estimators e redundante e desperdiça
    # trials — o early stopping corta de qualquer jeito sem o Optuna saber.
    return dict(
        max_depth=trial.suggest_int("max_depth", 3, 6),
        learning_rate=trial.suggest_float("learning_rate", 0.010, 0.08, log=True),
        subsample=trial.suggest_float("subsample", 0.60, 0.95),
        colsample_bytree=trial.suggest_float("colsample_bytree", 0.55, 0.95),
        reg_alpha=trial.suggest_float("reg_alpha", 0.0, 2.0),
        reg_lambda=trial.suggest_float("reg_lambda", 0.5, 5.0),
        min_child_weight=trial.suggest_float("min_child_weight", 2.0, 15.0),
        gamma=trial.suggest_float("gamma", 0.0, 0.8),
        aft_loss_distribution=trial.suggest_categorical(
            "aft_loss_distribution", ["normal", "logistic", "extreme"]
        ),
        aft_loss_distribution_scale=trial.suggest_float(
            "aft_loss_distribution_scale", 0.5, 3.0
        ),
    )


def _build_xgb_params(params: Dict[str, Any]) -> Dict[str, Any]:
    """Converte params do pipeline para params do xgb.train"""
    return {
        "objective": "survival:aft",
        "eval_metric": "aft-nloglik",
        "tree_method": "hist",
        "max_depth": int(params["max_depth"]),
        "learning_rate": float(params["learning_rate"]),
        "subsample": float(params["subsample"]),
        "colsample_bytree": float(params["colsample_bytree"]),
        "reg_alpha": float(params["reg_alpha"]),
        "reg_lambda": float(params["reg_lambda"]),
        "min_child_weight": float(params["min_child_weight"]),
        "gamma": float(params["gamma"]),
        "aft_loss_distribution": str(params["aft_loss_distribution"]),
        "aft_loss_distribution_scale": float(params["aft_loss_distribution_scale"]),
        "seed": RANDOM_SEED,
        "nthread": -1,
    }


def train_aft(params: Dict[str, Any], dtrain: xgb.DMatrix,
              deval: xgb.DMatrix) -> xgb.Booster:
    """Treina modelo AFT com early stopping"""
    xgb_params = _build_xgb_params(params)
    n_rounds = int(params.get("n_estimators", 3000))

    bst = xgb.train(
        xgb_params,
        dtrain,
        num_boost_round=n_rounds,
        evals=[(deval, "eval")],
        early_stopping_rounds=50,
        verbose_eval=False,
    )
    return bst


def predict_mfe(booster: xgb.Booster, dmat: xgb.DMatrix,
                best_iteration: Optional[int] = None) -> np.ndarray:
    """Prediz MFE em R-multiplos.
    survival:aft ja aplica exp() internamente (PredTransform) — resultado e MFE em escala original.
    NAO aplicar np.exp() aqui (isso causaria double-exponentiation).
    """
    if best_iteration is not None:
        raw = booster.predict(dmat, iteration_range=(0, best_iteration + 1))
    else:
        raw = booster.predict(dmat)
    return np.clip(raw, MFE_EPSILON, 100.0)


# ===========================================================================
# WALK-FORWARD & OPTUNA
# ===========================================================================


def walk_forward_score_aft(params: Dict[str, Any], df: pd.DataFrame,
                           folds: List[Fold]) -> Dict[str, Any]:
    """Avalia parametros AFT com walk-forward"""
    rows = []
    scores = []

    for i, fold in enumerate(folds, start=1):
        dtrain = make_dmatrix(df, fold.train_idx)
        deval = make_dmatrix(df, fold.early_stop_idx)
        dvalid = make_dmatrix(df, fold.valid_idx)

        bst = train_aft(params, dtrain, deval)
        best_iter = bst.best_iteration if hasattr(bst, "best_iteration") else None
        pred_mfe = predict_mfe(bst, dvalid, best_iter)

        # Avaliar usando multi-R: testa todos R targets, escolhe o melhor par
        valid_day_count = int(df.loc[fold.valid_idx, "trade_date"].nunique())

        best_r, mfe_thr, _, _ = choose_best_r_and_threshold(
            df, fold.valid_idx, pred_mfe, valid_day_count
        )
        y_eval_col = f"hit_{int(best_r)}R" if best_r == int(best_r) else f"hit_{best_r:.1f}R"
        if y_eval_col in df.columns:
            y_eval = df.loc[fold.valid_idx, y_eval_col].values.astype(int)
        else:
            y_eval = (df.loc[fold.valid_idx, "mfe"].values >= best_r).astype(int)
        metrics = evaluate_aft(y_eval, pred_mfe, mfe_thr, best_r, valid_day_count)

        # Score composto (mesmo espirito do modelo binario)
        score = (
            metrics["expected_r_per_trade"]
            + 0.35 * metrics["pr_auc"]
            + 0.05 * metrics["precision"]
            + 0.03 * metrics["trade_rate"]
        )
        if not np.isfinite(score):
            score = -10.0
        scores.append(score)
        rows.append({
            "fold": i,
            "mfe_threshold": mfe_thr,
            "score": score,
            "best_iteration": best_iter,
            **metrics,
        })

    mean_score = float(np.mean(scores))
    std_score = float(np.std(scores))
    return {
        "fold_rows": rows,
        "mean_score": mean_score,
        "std_score": std_score,
        "composite_score": mean_score - 0.50 * std_score,
    }


def tune_aft_params(df: pd.DataFrame, folds: List[Fold],
                    trials: int) -> Tuple[Dict[str, Any], Dict[str, Any]]:
    """Tuning com Optuna (ou default se nao disponivel)"""
    if not HAS_OPTUNA or trials <= 0:
        print(f"    [TUNE] Usando parametros default "
              f"(Optuna {'nao instalado' if not HAS_OPTUNA else 'trials=0'})")
        params = default_aft_params()
        payload = walk_forward_score_aft(params, df, folds)
        return params, {"used_optuna": False, "best_params": params, "walk_forward": payload}

    print(f"    [TUNE] Optuna: {trials} trials...")
    study = optuna.create_study(direction="maximize", study_name="AFT_MFE")

    def objective(trial: "optuna.Trial") -> float:
        params = suggest_aft_params(trial)
        payload = walk_forward_score_aft(params, df, folds)
        trial.set_user_attr("mean_score", payload["mean_score"])
        trial.set_user_attr("std_score", payload["std_score"])
        return payload["composite_score"]

    study.optimize(objective, n_trials=trials, show_progress_bar=True)
    params = dict(study.best_params)
    # n_estimators nao vem do Optuna (foi removido do suggest_aft_params),
    # entao sempre injetamos o valor fixo alto aqui para o treino final.
    params["n_estimators"] = 3000
    payload = walk_forward_score_aft(params, df, folds)

    print(f"    [TUNE] Melhor score: {study.best_value:.4f}")

    return params, {
        "used_optuna": True,
        "best_value": study.best_value,
        "best_params": params,
        "walk_forward": payload,
        "n_trials": len(study.trials),
    }


# ===========================================================================
# MQL5 EXPORT
# ===========================================================================


def _extract_aft_base_score(booster: xgb.Booster) -> float:
    """Extrai base_score do AFT (log-MFE intercept, sem logit)"""
    cfg = json.loads(booster.save_config())
    base_score_value = cfg["learner"]["learner_model_param"]["base_score"]
    if isinstance(base_score_value, str):
        cleaned = base_score_value.strip()
        if cleaned.startswith("[") and cleaned.endswith("]"):
            cleaned = cleaned[1:-1].strip()
        if "," in cleaned:
            cleaned = cleaned.split(",", 1)[0].strip()
        return float(cleaned)
    return float(base_score_value)


def _load_booster_json(booster: xgb.Booster) -> Dict[str, Any]:
    """Carrega modelo como JSON"""
    fd, tmp_path = tempfile.mkstemp(suffix=".json")
    os.close(fd)
    try:
        booster.save_model(tmp_path)
        return json.loads(Path(tmp_path).read_text(encoding="utf-8"))
    finally:
        try:
            Path(tmp_path).unlink(missing_ok=True)
        except Exception:
            pass


def _get_active_trees(booster: xgb.Booster,
                      best_iteration: Optional[int]) -> List[Dict[str, Any]]:
    """Retorna arvores ativas (ate best_iteration)"""
    full_model = _load_booster_json(booster)
    trees = full_model["learner"]["gradient_booster"]["model"]["trees"]
    if best_iteration is not None:
        trees = trees[: int(best_iteration) + 1]
    return trees


def _compute_effective_base_score(booster: xgb.Booster,
                                   trees: List[Dict[str, Any]],
                                   x_df: pd.DataFrame,
                                   best_iteration: Optional[int]) -> float:
    """Computa o base_score efetivo calibrado contra output_margin=True.
    Usa multiplas amostras (ate 50) para calibracao robusta.
    Compara em log-space (output_margin=True) onde nao ha amplificacao do exp().
    """
    base_score_raw = _extract_aft_base_score(booster)

    # Usa ate 50 amostras para calibracao robusta
    n_calib = min(50, len(x_df))
    calib_df = x_df.iloc[:n_calib]
    calib_dmat = xgb.DMatrix(calib_df, feature_names=list(x_df.columns))

    # Raw log-scores do booster (antes do exp() interno do AFT)
    if best_iteration is not None:
        direct_preds = booster.predict(calib_dmat, output_margin=True,
                                       iteration_range=(0, best_iteration + 1))
    else:
        direct_preds = booster.predict(calib_dmat, output_margin=True)

    # Travessia manual para todas as amostras de calibracao
    x_values = calib_df.to_numpy(dtype=float)
    corrections = []
    for i, row in enumerate(x_values):
        manual_score = base_score_raw
        for tree in trees:
            node = 0
            while True:
                left = int(tree["left_children"][node])
                right = int(tree["right_children"][node])
                if left == -1 and right == -1:
                    manual_score += float(tree["base_weights"][node])
                    break
                feat_idx = int(tree["split_indices"][node])
                threshold = float(tree["split_conditions"][node])
                value = row[feat_idx]
                if not np.isfinite(value):
                    node = left if int(tree["default_left"][node]) == 1 else right
                elif value < threshold:
                    node = left
                else:
                    node = right
        # correcao = quanto o base_score precisa ser ajustado para este sample
        corrections.append(direct_preds[i] - manual_score)

    corrections = np.array(corrections)
    mean_correction = float(corrections.mean())
    std_correction = float(corrections.std())

    if abs(mean_correction) > 1e-6:
        corrected = base_score_raw + mean_correction
        print(f"    [MQL5] base_score calibrado: {base_score_raw:.8f} -> {corrected:.8f} "
              f"(correcao media={mean_correction:.2e}, std={std_correction:.2e}, n={n_calib})")
        return corrected

    return base_score_raw


def _predict_aft_export_equivalent(booster: xgb.Booster,
                                   x_df: pd.DataFrame,
                                   best_iteration: Optional[int]) -> np.ndarray:
    """Replica exata da predicao MQL5 em Python para validacao 1:1"""
    trees = _get_active_trees(booster, best_iteration)
    base_score = _compute_effective_base_score(booster, trees, x_df, best_iteration)
    x_values = x_df.to_numpy(dtype=float)

    predictions = []
    for row in x_values:
        score = base_score
        for tree in trees:
            split_indices = tree["split_indices"]
            split_conditions = tree["split_conditions"]
            left_children = tree["left_children"]
            right_children = tree["right_children"]
            default_left = tree["default_left"]
            base_weights = tree["base_weights"]
            node = 0
            while True:
                left = int(left_children[node])
                right = int(right_children[node])
                if left == -1 and right == -1:
                    score += float(base_weights[node])
                    break
                feat_idx = int(split_indices[node])
                threshold = float(split_conditions[node])
                value = row[feat_idx]
                if not np.isfinite(value):
                    node = left if int(default_left[node]) == 1 else right
                elif value < threshold:
                    node = left
                else:
                    node = right
        predictions.append(math.exp(score))

    return np.asarray(predictions)


def export_aft_to_mql5(booster: xgb.Booster, feature_names: List[str],
                       output_dir: Path, mfe_threshold: float,
                       best_iteration: Optional[int],
                       verification_x: pd.DataFrame,
                       verification_mfe: np.ndarray
                       ) -> Tuple[Optional[Path], Dict[str, Any]]:
    """Exporta XGBoost AFT para MQL5 .mqh — MathExp(score) ao inves de sigmoid"""
    try:
        trees = _get_active_trees(booster, best_iteration)
        # Usa base_score calibrado (nao o do config que pode ser 0.5 padrao)
        base_score = _compute_effective_base_score(booster, trees, verification_x, best_iteration)

        PREFIX = "POIAFT"

        lines = [
            "//+------------------------------------------------------------------+",
            "//| XGBoost AFT — Survival MFE Prediction                           |",
            f"//| Trees: {len(trees)}  Features: {len(feature_names)}                            |",
            f"//| Gerado: {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}                         |",
            "//+------------------------------------------------------------------+",
            "#property strict",
            f"#define {PREFIX}_N_TREES {len(trees)}",
            f"#define {PREFIX}_N_FEATURES {len(feature_names)}",
            f"static const double {PREFIX}_BASE_SCORE = {base_score:.16f};",
            f"static const double {PREFIX}_MFE_THRESHOLD = {mfe_threshold:.16f};",
            "",
        ]

        # Feature map
        for idx, feat_name in enumerate(feature_names):
            lines.append(f"// Feature[{idx:02d}] = {feat_name}")
        lines.append("")

        # Per-tree arrays + traversal function
        for i, tree in enumerate(trees):
            n_nodes = len(tree["left_children"])
            lines.append(f"static const int {PREFIX}_T{i}_NODES = {n_nodes};")
            lines.append(
                f"static const int {PREFIX}_T{i}_SPLIT_IDX[] = {{ "
                + ", ".join(str(int(v)) for v in tree["split_indices"])
                + " };"
            )
            lines.append(
                f"static const double {PREFIX}_T{i}_SPLIT_COND[] = {{ "
                + ", ".join(f"{float(v):.16f}" for v in tree["split_conditions"])
                + " };"
            )
            lines.append(
                f"static const int {PREFIX}_T{i}_LEFT[] = {{ "
                + ", ".join(str(int(v)) for v in tree["left_children"])
                + " };"
            )
            lines.append(
                f"static const int {PREFIX}_T{i}_RIGHT[] = {{ "
                + ", ".join(str(int(v)) for v in tree["right_children"])
                + " };"
            )
            lines.append(
                f"static const int {PREFIX}_T{i}_DEFAULT_LEFT[] = {{ "
                + ", ".join(str(int(v)) for v in tree["default_left"])
                + " };"
            )
            lines.append(
                f"static const double {PREFIX}_T{i}_WEIGHT[] = {{ "
                + ", ".join(f"{float(v):.16f}" for v in tree["base_weights"])
                + " };"
            )
            lines.append(f"double {PREFIX}_Tree{i}(const double &f[])")
            lines.append("{")
            lines.append("   int node = 0;")
            lines.append("   while(true)")
            lines.append("   {")
            lines.append(f"      int left = {PREFIX}_T{i}_LEFT[node];")
            lines.append(f"      int right = {PREFIX}_T{i}_RIGHT[node];")
            lines.append("      if(left == -1 && right == -1)")
            lines.append(f"         return {PREFIX}_T{i}_WEIGHT[node];")
            lines.append(f"      int feat_idx = {PREFIX}_T{i}_SPLIT_IDX[node];")
            lines.append(f"      double threshold = {PREFIX}_T{i}_SPLIT_COND[node];")
            lines.append("      double value = f[feat_idx];")
            lines.append("      if(!MathIsValidNumber(value))")
            lines.append(
                f"         node = ({PREFIX}_T{i}_DEFAULT_LEFT[node] == 1 ? left : right);"
            )
            lines.append("      else if(value < threshold)")
            lines.append("         node = left;")
            lines.append("      else")
            lines.append("         node = right;")
            lines.append("   }")
            lines.append("}")
            lines.append("")

        # Aggregate predict — AFT: MathExp(score)
        lines.append(f"double {PREFIX}_PredictMFE(const double &f[])")
        lines.append("{")
        lines.append(f"   if(ArraySize(f) < {PREFIX}_N_FEATURES) return 0.0;")
        lines.append(f"   double score = {PREFIX}_BASE_SCORE;")
        for i in range(len(trees)):
            lines.append(f"   score += {PREFIX}_Tree{i}(f);")
        lines.append("   return MathExp(score);  // predicted MFE em R-multiplos")
        lines.append("}")

        out_path = output_dir / "ROBOSMC_V810_ML1_Model_AFT_POI.mqh"
        out_path.write_text("\n".join(lines), encoding="utf-8")

        # Validacao 1:1 Python vs MQL5
        # Validacao em log-space (raw score) para evitar amplificacao do exp()
        # Um erro de 0.01 em log-space vira 1% de erro em MFE — aceitavel para trading
        print("    [MQL5] Validacao 1:1 (log-space)...")
        exported_mfe = _predict_aft_export_equivalent(
            booster, verification_x, best_iteration
        )

        # Erro absoluto em MFE-space (pode ser grande para predicoes altas por exp amplification)
        diff_abs = np.abs(exported_mfe - verification_mfe)

        # Erro relativo em MFE-space (mais justo para toda a gama de valores)
        rel_diff = diff_abs / np.maximum(verification_mfe, MFE_EPSILON)

        # Erro em log-space (canonico para AFT — onde o modelo de fato opera)
        log_exported = np.log(np.maximum(exported_mfe, MFE_EPSILON))
        log_reference = np.log(np.maximum(verification_mfe, MFE_EPSILON))
        diff_log = np.abs(log_exported - log_reference)

        # Verificacao de decisao de trading: o sinal (acima/abaixo do threshold) e o mesmo?
        decision_exported   = exported_mfe   >= mfe_threshold
        decision_reference  = verification_mfe >= mfe_threshold
        decision_match_pct  = float((decision_exported == decision_reference).mean())

        verification = {
            "rows_checked": int(len(verification_x)),
            "max_abs_diff": float(diff_abs.max()) if len(diff_abs) else 0.0,
            "mean_abs_diff": float(diff_abs.mean()) if len(diff_abs) else 0.0,
            "max_rel_diff_pct": float(rel_diff.max() * 100) if len(rel_diff) else 0.0,
            "mean_rel_diff_pct": float(rel_diff.mean() * 100) if len(rel_diff) else 0.0,
            "max_log_diff": float(diff_log.max()) if len(diff_log) else 0.0,
            "mean_log_diff": float(diff_log.mean()) if len(diff_log) else 0.0,
            # OK se erro em log-space < 0.01 (equiv. a ~1% em MFE-space)
            "all_match_log_1pct": bool((diff_log < 0.01).all()) if len(diff_log) else True,
            "all_match_log_2pct": bool((diff_log < 0.02).all()) if len(diff_log) else True,
            "decision_match_pct": decision_match_pct,
            "mfe_threshold": float(mfe_threshold),
            "base_score": float(base_score),
            "active_tree_count": int(len(trees)),
            "best_iteration": best_iteration,
            "prefix": PREFIX,
            "predict_function": f"{PREFIX}_PredictMFE",
        }

        # A metrica que realmente importa para trading e a decisao (acima/abaixo threshold)
        if verification["decision_match_pct"] >= 0.999:
            if verification["all_match_log_1pct"]:
                print(f"    [MQL5] VALIDACAO OK — log_max={diff_log.max():.2e} "
                      f"decisao={decision_match_pct:.1%}")
            else:
                print(f"    [MQL5] VALIDACAO OK (decisao {decision_match_pct:.1%} correta) — "
                      f"log_max={diff_log.max():.2e} log_mean={diff_log.mean():.2e} "
                      f"[amplificacao exp em predicoes extremas, sem impacto no sinal]")
        else:
            print(f"    [MQL5] ATENCAO — decisao={decision_match_pct:.1%} | "
                  f"log_max={diff_log.max():.2e} log_mean={diff_log.mean():.2e}")

        return out_path, verification

    except Exception as exc:
        tb = traceback.format_exc(limit=6)
        print(f"    [MQL5] ERRO na exportacao: {exc}")
        return None, {"error": "export_failed", "message": str(exc), "traceback": tb}


# ===========================================================================
# CHARTS / PLOTS
# ===========================================================================


def save_importance_plot(df: pd.DataFrame, title: str, out: Path,
                         value_col: str) -> None:
    top = df.head(TOP_IMPORTANCE).iloc[::-1]
    plt.figure(figsize=(11, 8))
    plt.barh(top["feature"], top[value_col], color="#0f766e")
    plt.title(title)
    plt.xlabel(value_col)
    plt.tight_layout()
    plt.savefig(out, dpi=160)
    plt.close()


def plot_mfe_distribution(predicted_mfe: np.ndarray, actual_mfe: np.ndarray,
                          censored: np.ndarray, mfe_threshold: float,
                          output_dir: Path) -> None:
    """Distribuicao do MFE predito vs real"""
    fig, (ax1, ax2) = plt.subplots(1, 2, figsize=(14, 5))

    # Predicted MFE
    bins = np.linspace(0, 6, 50)
    ax1.hist(predicted_mfe, bins=bins, alpha=0.7, color="#2563eb", label="Predicted MFE")
    ax1.axvline(mfe_threshold, color="red", linestyle="--", linewidth=2,
                label=f"Threshold={mfe_threshold:.2f}")
    ax1.set_xlabel("Predicted MFE (R-multiplos)")
    ax1.set_ylabel("Frequencia")
    ax1.set_title("Distribuicao do MFE Predito")
    ax1.legend()
    ax1.grid(alpha=0.3)

    # Actual MFE (separando censurados)
    uncensored_mfe = actual_mfe[censored == 0]
    censored_mfe = actual_mfe[censored == 1]
    ax2.hist(uncensored_mfe, bins=bins, alpha=0.5, color="#22c55e", label="Exato")
    ax2.hist(censored_mfe, bins=bins, alpha=0.5, color="#f97316", label="Censurado (>=)")
    ax2.set_xlabel("Actual MFE (R-multiplos)")
    ax2.set_ylabel("Frequencia")
    ax2.set_title("Distribuicao do MFE Real")
    ax2.legend()
    ax2.grid(alpha=0.3)

    fig.suptitle("AFT — Predicted vs Actual MFE", fontsize=13)
    fig.tight_layout()
    fig.savefig(output_dir / "aft_mfe_distribution.png", dpi=160)
    plt.close(fig)


def plot_predicted_vs_actual(predicted_mfe: np.ndarray, actual_mfe: np.ndarray,
                             censored: np.ndarray, output_dir: Path) -> None:
    """Scatter: predicted vs actual MFE"""
    fig, ax = plt.subplots(figsize=(8, 8))

    uncensored = censored == 0
    ax.scatter(predicted_mfe[uncensored], actual_mfe[uncensored],
               alpha=0.3, s=8, c="#2563eb", label="Exato")
    ax.scatter(predicted_mfe[~uncensored], actual_mfe[~uncensored],
               alpha=0.3, s=8, c="#f97316", marker="^", label="Censurado")

    max_val = max(predicted_mfe.max(), actual_mfe.max()) * 1.05
    ax.plot([0, max_val], [0, max_val], "k--", alpha=0.5, label="Ideal (y=x)")
    ax.set_xlabel("Predicted MFE")
    ax.set_ylabel("Actual MFE")
    ax.set_title("AFT — Predicted vs Actual MFE")
    ax.legend()
    ax.grid(alpha=0.3)
    ax.set_xlim(0, min(max_val, 6))
    ax.set_ylim(0, min(max_val, 6))

    fig.tight_layout()
    fig.savefig(output_dir / "aft_predicted_vs_actual.png", dpi=160)
    plt.close(fig)


def plot_threshold_analysis_aft(predicted_mfe: np.ndarray, y_true_dict: Dict[str, np.ndarray],
                                day_count: int, chosen_threshold: float,
                                output_dir: Path) -> None:
    """Analise de threshold para multiplos R targets"""
    thresholds = np.arange(0.5, 5.5, 0.05)
    n_targets = len(y_true_dict)
    fig, axes = plt.subplots(1, n_targets, figsize=(7 * n_targets, 5))
    if n_targets == 1:
        axes = [axes]

    for ax, (r_label, y_true) in zip(axes, y_true_dict.items()):
        r_val = float(r_label.replace("R", "").replace("hit_", ""))
        exp_r_year = []
        precisions = []
        win_rates = []
        trades_year = []

        for thr in thresholds:
            take = predicted_mfe >= thr
            freq = trade_frequency(take, day_count)
            er = expected_r(y_true, take, r_val)
            exp_r_year.append(
                er * freq["trades_per_year"]
                if np.isfinite(er) else float("nan")
            )
            precisions.append(
                precision_score(y_true, take.astype(int), zero_division=0)
            )
            wr = ((y_true == 1) & take).sum() / max(1, take.sum())
            win_rates.append(wr)
            trades_year.append(freq["trades_per_year"])

        ax.plot(thresholds, exp_r_year, label="E[R]/year", color="#0f766e", linewidth=2)
        ax.plot(thresholds, precisions, label="Precision (Win Rate)", color="#ea580c")
        ax2 = ax.twinx()
        ax2.plot(thresholds, trades_year, label="Trades/year", color="#7c3aed",
                 linestyle="--", alpha=0.6)
        ax2.set_ylabel("Trades/year", color="#7c3aed")

        ax.axvline(chosen_threshold, color="red", linestyle="--", linewidth=2,
                   label=f"Chosen={chosen_threshold:.2f}")
        ax.set_title(f"TP={r_label}")
        ax.set_xlabel("MFE Threshold")
        ax.set_ylabel("E[R]/year, Precision")
        ax.grid(alpha=0.3)
        ax.legend(fontsize=8, loc="upper left")
        ax2.legend(fontsize=8, loc="upper right")

    fig.suptitle("AFT — Threshold Analysis (Multi-R)", fontsize=13)
    fig.tight_layout()
    fig.savefig(output_dir / "aft_threshold_analysis.png", dpi=160)
    plt.close(fig)


def plot_equity_curve_aft(predicted_mfe: np.ndarray,
                          y_true_dict: Dict[str, np.ndarray],
                          mfe_threshold: float,
                          output_dir: Path) -> None:
    """Equity curve simulada para multiplos R targets"""
    fig, ax = plt.subplots(figsize=(12, 5))
    take = predicted_mfe >= mfe_threshold

    for r_label, y_true in y_true_dict.items():
        r_val = float(r_label.replace("R", "").replace("hit_", ""))
        cumulative = 0.0
        pnl = []
        for i in range(len(take)):
            if take[i]:
                r = r_val if y_true[i] == 1 else R_NEG
                cumulative += r
            pnl.append(cumulative)
        ax.plot(pnl, label=f"TP={r_label} (thr={mfe_threshold:.2f})", linewidth=1.5)

    ax.set_xlabel("Sample sequencial (test set)")
    ax.set_ylabel("R-multiplos acumulados")
    ax.set_title("AFT — Equity Curve simulada (test OOS)")
    ax.legend()
    ax.grid(alpha=0.3)
    ax.axhline(0, color="black", linewidth=0.5)
    fig.tight_layout()
    fig.savefig(output_dir / "aft_equity_curve.png", dpi=160)
    plt.close(fig)


def shap_analysis_aft(booster: xgb.Booster, x_sample: pd.DataFrame,
                      feature_names: List[str], output_dir: Path
                      ) -> Optional[pd.DataFrame]:
    """SHAP feature importance para AFT"""
    if not HAS_SHAP:
        print(f"    [SHAP] shap nao instalado — pulando")
        return None
    if len(x_sample) == 0:
        return None
    if len(x_sample) > SHAP_MAX_SAMPLES:
        x_eval = x_sample.sample(n=SHAP_MAX_SAMPLES, random_state=RANDOM_SEED)
    else:
        x_eval = x_sample.copy()
    try:
        explainer = shap.TreeExplainer(booster)
        shap_values = explainer.shap_values(x_eval)
        if isinstance(shap_values, list):
            shap_values = shap_values[-1]

        fig = plt.figure(figsize=(10, 8))
        shap.summary_plot(shap_values, x_eval, feature_names=feature_names,
                          plot_type="dot", show=False, max_display=25)
        plt.title("SHAP Summary — AFT MFE")
        plt.tight_layout()
        fig.savefig(output_dir / "aft_shap_summary.png", dpi=160, bbox_inches="tight")
        plt.close(fig)

        fig = plt.figure(figsize=(9, 7))
        shap.summary_plot(shap_values, x_eval, feature_names=feature_names,
                          plot_type="bar", show=False, max_display=25)
        plt.title("SHAP Importance — AFT MFE")
        plt.tight_layout()
        fig.savefig(output_dir / "aft_shap_bar.png", dpi=160, bbox_inches="tight")
        plt.close(fig)

        shap_df = pd.DataFrame({
            "feature": feature_names,
            "shap_mean_abs": np.abs(shap_values).mean(axis=0),
        }).sort_values("shap_mean_abs", ascending=False).reset_index(drop=True)
        shap_df.to_csv(output_dir / "aft_shap_importance.csv", index=False)
        return shap_df
    except Exception as e:
        print(f"    [SHAP] Erro: {e}")
        return None


# ===========================================================================
# MAIN PIPELINE
# ===========================================================================


def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser(description="Pipeline ML AFT — RoboSMC v810")
    p.add_argument("--dataset", default=DATASET_DEFAULT,
                   help="Caminho para CSV do dataset")
    p.add_argument("--optuna-trials", type=int, default=100,
                   help="Trials Optuna")
    p.add_argument("--outdir", default=None,
                   help="Diretorio de saida (auto se omitido)")
    p.add_argument("--skip-shap", action="store_true",
                   help="Pular analise SHAP")
    p.add_argument("--skip-charts", action="store_true",
                   help="Pular geracao de graficos")
    p.add_argument("--export-mql", action="store_true",
                   help="Exportar .mqh para MQL5")
    p.add_argument("--primary-r", type=float, default=PRIMARY_R_TARGET,
                   help=f"R target primario (default={PRIMARY_R_TARGET})")
    p.add_argument("--retrain-full", action="store_true",
                   help="Apos avaliacao, retreina com 100%% dos dados e exporta .mqh final de producao")
    return p.parse_args()


def make_output_dir(dataset_path: Path, explicit_outdir: Optional[str]) -> Path:
    if explicit_outdir:
        outdir = Path(explicit_outdir)
    else:
        outdir = (dataset_path.parent / "training_runs_AFT"
                  / f"run_{datetime.now().strftime('%Y%m%d_%H%M%S')}")
    outdir.mkdir(parents=True, exist_ok=True)
    return outdir


def main() -> None:
    args = parse_args()
    global PRIMARY_R_TARGET
    PRIMARY_R_TARGET = args.primary_r

    dataset_path = Path(args.dataset)
    outdir = make_output_dir(dataset_path, args.outdir)

    print("=" * 70)
    print("  PIPELINE ML AFT — XGBoost Survival (MFE continuo)")
    print(f"  R targets: {EVAL_R_TARGETS} | Primario: {PRIMARY_R_TARGET}")
    print(f"  Dataset: {dataset_path}")
    print(f"  Output: {outdir}")
    print(f"  Optuna: {'sim' if HAS_OPTUNA else 'nao'} ({args.optuna_trials} trials)")
    print(f"  SHAP: {'sim' if HAS_SHAP and not args.skip_shap else 'nao'}")
    print(f"  Export MQL5: {'sim' if args.export_mql else 'nao'}")
    print("=" * 70)

    t0 = time.time()

    # ==== LOAD DATA ====
    print("\n[1/7] Carregando dataset...")
    df = load_dataset(dataset_path)
    split = build_final_split(df)
    folds = build_walk_forward_folds(df, split)

    # ==== TUNING ====
    print("\n[2/7] Tuning hiperparametros (walk-forward)...")
    params, tuning_report = tune_aft_params(df, folds, args.optuna_trials)
    print(f"    [PARAMS] {json.dumps({k: round(v, 4) if isinstance(v, float) else v for k, v in params.items()}, indent=None)}")

    # ==== TREINO FINAL ====
    print("\n[3/7] Treinando modelo final...")
    final_fit_idx, final_es_idx = build_early_stop_split(df, split.train_idx)

    dtrain = make_dmatrix(df, final_fit_idx)
    deval = make_dmatrix(df, final_es_idx)
    booster = train_aft(params, dtrain, deval)

    best_iter = getattr(booster, "best_iteration", None)
    if best_iter is not None:
        print(f"    [FIT] Best iteration: {best_iter}")
    print(f"    [FIT] Train: {len(final_fit_idx)} | Early stop: {len(final_es_idx)}")

    # ==== THRESHOLD SELECTION (MULTI-R) ====
    print("\n[4/7] Selecionando MFE threshold (multi-R)...")
    dthr = xgb.DMatrix(
        df.loc[split.thr_idx, FEATURE_COLUMNS], feature_names=FEATURE_COLUMNS
    )
    thr_pred_mfe = predict_mfe(booster, dthr, best_iter)
    thr_day_count = int(df.loc[split.thr_idx, "trade_date"].nunique())

    selected_r, mfe_threshold, thr_metrics, thr_grid = choose_best_r_and_threshold(
        df, split.thr_idx, thr_pred_mfe, thr_day_count
    )
    print(f"    [THR] R target selecionado: {selected_r:.1f}R")
    print(f"    [THR] MFE threshold selecionado: {mfe_threshold:.3f}")
    print(f"    [THR] E[R]/trade={thr_metrics.get('expected_r_per_trade', 0):.4f} | "
          f"trades/year={thr_metrics.get('trades_per_year', 0):.0f}")

    # ==== AVALIACAO TEST SET ====
    print("\n[5/7] Avaliando no test set (OOS)...")
    dtest = xgb.DMatrix(
        df.loc[split.test_idx, FEATURE_COLUMNS], feature_names=FEATURE_COLUMNS
    )
    test_pred_mfe = predict_mfe(booster, dtest, best_iter)
    test_day_count = int(df.loc[split.test_idx, "trade_date"].nunique())

    # Metricas para cada R target
    multi_r_results: Dict[float, Dict[str, Any]] = {}
    for r_target in EVAL_R_TARGETS:
        col = f"hit_{int(r_target)}R"
        if col in df.columns:
            y_test = df.loc[split.test_idx, col].values.astype(int)
        else:
            y_test = (df.loc[split.test_idx, "mfe"].values >= r_target).astype(int)
        metrics = evaluate_aft(y_test, test_pred_mfe, mfe_threshold, r_target, test_day_count)
        multi_r_results[r_target] = metrics

        is_selected = " (SELECIONADO)" if r_target == selected_r else ""
        r_label = f"{int(r_target)}R" if r_target == int(r_target) else f"{r_target:.1f}R"
        print(f"\n    [TEST OOS] TP={r_label}{is_selected}")
        print(f"      ROC-AUC={metrics['roc_auc']:.4f} | PR-AUC={metrics['pr_auc']:.4f}")
        print(f"      Precision={metrics['precision']:.4f} | "
              f"Win Rate={metrics['win_rate']:.4f}")
        print(f"      E[R]/trade={metrics['expected_r_per_trade']:.4f} | "
              f"E[R]/year={metrics['expected_r_per_year']:.1f}")
        print(f"      Profit Factor={metrics['profit_factor']:.2f} | "
              f"Trades={metrics['trade_count']} ({metrics['trades_per_year']:.0f}/yr)")

    test_primary_metrics = multi_r_results.get(selected_r, multi_r_results[PRIMARY_R_TARGET])

    # C-index — so end_reason=1 (MaxR cap) e censurado por cima
    test_actual_mfe = df.loc[split.test_idx, "mfe"].values
    test_censor_for_cindex = (df.loc[split.test_idx, "end_reason"].values == 1).astype(int)

    c_index = concordance_index_simple(test_pred_mfe, test_actual_mfe, test_censor_for_cindex)
    print(f"\n    [TEST OOS] C-index: {c_index:.4f}")

    # MFE prediction stats
    print(f"    [TEST OOS] Predicted MFE: mean={test_pred_mfe.mean():.3f} | "
          f"median={np.median(test_pred_mfe):.3f} | "
          f"std={test_pred_mfe.std():.3f}")

    # ==== FEATURE IMPORTANCE ====
    print("\n[6/7] Feature importance...")

    # Gain-based importance
    importance_raw = booster.get_score(importance_type="gain")
    fi_model = pd.DataFrame([
        {"feature": k, "importance": float(v)}
        for k, v in importance_raw.items()
    ]).sort_values("importance", ascending=False).reset_index(drop=True)

    # Preencher features ausentes (nunca usadas em splits)
    used_features = set(fi_model["feature"])
    for f in FEATURE_COLUMNS:
        if f not in used_features:
            fi_model = pd.concat([
                fi_model, pd.DataFrame([{"feature": f, "importance": 0.0}])
            ], ignore_index=True)
    fi_model = fi_model.sort_values("importance", ascending=False).reset_index(drop=True)

    # Permutation importance
    print("    [PERM] Calculando permutation importance...")
    wrapper = AFTBoosterWrapper(booster, FEATURE_COLUMNS, best_iter or 0)
    from sklearn.metrics import make_scorer
    _pr_auc_scorer = make_scorer(
        lambda y_true, y_pred: average_precision_score(y_true, y_pred),
        response_method="predict",
    )

    # Construir y para permutation importance usando o R selecionado
    _perm_col = f"hit_{int(selected_r)}R" if selected_r == int(selected_r) else None
    if _perm_col and _perm_col in df.columns:
        _y_perm = df.loc[split.thr_idx, _perm_col].values.astype(int)
    else:
        _y_perm = (df.loc[split.thr_idx, "mfe"].values >= selected_r).astype(int)

    try:
        perm_result = permutation_importance(
            wrapper,
            df.loc[split.thr_idx, FEATURE_COLUMNS],
            _y_perm,
            scoring=_pr_auc_scorer,
            n_repeats=PERM_REPEATS,
            random_state=RANDOM_SEED,
            n_jobs=1,
        )
        fi_perm = (
            pd.DataFrame({
                "feature": FEATURE_COLUMNS,
                "importance_mean": perm_result.importances_mean,
                "importance_std": perm_result.importances_std,
            })
            .sort_values("importance_mean", ascending=False)
            .reset_index(drop=True)
        )
    except Exception as e:
        print(f"    [PERM] Erro: {e}")
        fi_perm = pd.DataFrame({
            "feature": FEATURE_COLUMNS,
            "importance_mean": [0.0] * len(FEATURE_COLUMNS),
            "importance_std": [0.0] * len(FEATURE_COLUMNS),
        })

    # Save CSVs
    fi_model.to_csv(outdir / "aft_feature_importance_model.csv", index=False)
    fi_perm.to_csv(outdir / "aft_feature_importance_permutation.csv", index=False)
    thr_grid.to_csv(outdir / "aft_threshold_sweep.csv", index=False)

    # Save importance plots
    save_importance_plot(fi_model, "AFT — Model Importance (Gain)",
                        outdir / "aft_feature_importance_model.png", "importance")
    save_importance_plot(fi_perm, "AFT — Permutation Importance",
                        outdir / "aft_feature_importance_permutation.png", "importance_mean")

    # SHAP
    if not args.skip_shap:
        shap_analysis_aft(booster, df.loc[split.test_idx, FEATURE_COLUMNS],
                          FEATURE_COLUMNS, outdir)

    # Charts
    if not args.skip_charts:
        print("    [CHARTS] Gerando graficos...")

        # y_true dict para multi-R charts
        y_true_dict = {}
        for r_target in EVAL_R_TARGETS:
            col = f"hit_{int(r_target)}R"
            label = f"{int(r_target)}R" if r_target == int(r_target) else f"{r_target:.1f}R"
            if col in df.columns:
                y_true_dict[label] = df.loc[split.test_idx, col].values.astype(int)
            else:
                y_true_dict[label] = (df.loc[split.test_idx, "mfe"].values >= r_target).astype(int)

        plot_mfe_distribution(test_pred_mfe, test_actual_mfe, test_censor_for_cindex,
                              mfe_threshold, outdir)
        plot_predicted_vs_actual(test_pred_mfe, test_actual_mfe, test_censor_for_cindex, outdir)
        plot_threshold_analysis_aft(test_pred_mfe, y_true_dict, test_day_count,
                                   mfe_threshold, outdir)
        plot_equity_curve_aft(test_pred_mfe, y_true_dict, mfe_threshold, outdir)

    # Predictions CSV
    pred_df = df.loc[split.test_idx, [
        "id", "entry_time", "poi_id", "poi_tag", "poi_bias",
        "mfe", "mae", "censored", "end_reason",
    ]].copy()
    for r_target in EVAL_R_TARGETS:
        col = f"hit_{int(r_target)}R"
        if col in df.columns:
            pred_df[col] = df.loc[split.test_idx, col].values
        else:
            pred_df[col] = (df.loc[split.test_idx, "mfe"].values >= r_target).astype(int)
    pred_df["predicted_mfe"] = test_pred_mfe
    pred_df["take_trade"] = (test_pred_mfe >= mfe_threshold).astype(int)
    pred_df["mfe_threshold"] = mfe_threshold
    pred_df.to_csv(outdir / "aft_test_predictions.csv", index=False)

    # MQL5 export
    if args.export_mql:
        print("\n    [MQL5] Exportando XGBoost AFT...")
        x_test_df = df.loc[split.test_idx, FEATURE_COLUMNS]
        export_path, export_report = export_aft_to_mql5(
            booster, FEATURE_COLUMNS, outdir, mfe_threshold,
            best_iter, x_test_df, test_pred_mfe,
        )
    else:
        export_path = None
        export_report = None

    # Full report JSON
    report = {
        "pipeline": "train_AFT_model_POI.py",
        "model_type": "xgboost_survival_aft",
        "selected_r_target": selected_r,
        "primary_r_target": PRIMARY_R_TARGET,
        "eval_r_targets": EVAL_R_TARGETS,
        "best_params": params,
        "walk_forward_tuning": tuning_report,
        "mfe_threshold": mfe_threshold,
        "threshold_metrics": thr_metrics,
        "test_metrics_primary": test_primary_metrics,
        "test_metrics_multi_r": {
            (f"{int(r)}R" if r == int(r) else f"{r:.1f}R"): m
            for r, m in multi_r_results.items()
        },
        "c_index": c_index,
        "predicted_mfe_stats": {
            "mean": float(test_pred_mfe.mean()),
            "median": float(np.median(test_pred_mfe)),
            "std": float(test_pred_mfe.std()),
            "min": float(test_pred_mfe.min()),
            "max": float(test_pred_mfe.max()),
        },
        "dataset_stats": {
            "total_rows": int(len(df)),
            "exact_observations": int((df["end_reason"] != 1).sum()),
            "censored_maxr": int((df["end_reason"] == 1).sum()),
            "censored_session": int((df["end_reason"] == 2).sum()),
            "censored_maxbars": int((df["end_reason"] == 3).sum()),
        },
        "split": {
            "train_rows": int(len(split.train_idx)),
            "threshold_rows": int(len(split.thr_idx)),
            "test_rows": int(len(split.test_idx)),
        },
        "final_fit_rows": int(len(final_fit_idx)),
        "final_early_stop_rows": int(len(final_es_idx)),
        "best_iteration": best_iter,
        "feature_count": len(FEATURE_COLUMNS),
        "feature_names": FEATURE_COLUMNS,
        "top_10_model_importance": fi_model.head(10).to_dict(orient="records"),
        "top_10_permutation_importance": fi_perm.head(10).to_dict(orient="records"),
        "mql5_export_path": None if export_path is None else str(export_path),
        "mql5_export_verification": export_report,
    }

    # Metadata
    metadata = {
        "pipeline": "train_AFT_model_POI.py",
        "model_type": "xgboost_survival_aft",
        "primary_r_target": PRIMARY_R_TARGET,
        "eval_r_targets": EVAL_R_TARGETS,
        "dataset_path": str(dataset_path),
        "feature_count": len(FEATURE_COLUMNS),
        "feature_names": FEATURE_COLUMNS,
        "rows_total": int(len(df)),
        "rows_train": int(len(split.train_idx)),
        "rows_threshold": int(len(split.thr_idx)),
        "rows_test": int(len(split.test_idx)),
        "days_total": int(df["trade_date"].nunique()),
        "session_start": SESSION_START,
        "session_end": SESSION_END,
        "embargo_days": EMBARGO_DAYS,
        "wf_folds": WF_FOLDS,
        "optuna_installed": HAS_OPTUNA,
        "optuna_trials_requested": args.optuna_trials,
        "trading_days_per_year": TRADING_DAYS_PER_YEAR,
        "target_trades_per_year_min": TARGET_TRADES_PER_YEAR_MIN,
        "target_trades_per_year_max": TARGET_TRADES_PER_YEAR_MAX,
    }

    (outdir / "aft_report.json").write_text(
        json.dumps(report, indent=2, default=str), encoding="utf-8"
    )
    (outdir / "aft_run_metadata.json").write_text(
        json.dumps(metadata, indent=2), encoding="utf-8"
    )

    # ==== RETRAIN FULL (producao) ====
    if args.retrain_full:
        print("\n" + "=" * 70)
        print("  RETRAIN FULL — Treinando com 100% dos dados para producao")
        print("=" * 70)

        # Usa todos os indices disponiveis
        all_idx = df.index
        full_fit_idx, full_es_idx = build_early_stop_split(df, all_idx)

        print(f"  [FULL] Fit: {len(full_fit_idx)} samples ({df.loc[full_fit_idx, 'trade_date'].nunique()}d)")
        print(f"  [FULL] Early stop: {len(full_es_idx)} samples ({df.loc[full_es_idx, 'trade_date'].nunique()}d)")
        print(f"  [FULL] Params: {json.dumps({k: round(v,4) if isinstance(v,float) else v for k,v in params.items()})}")

        dtrain_full = make_dmatrix(df, full_fit_idx)
        deval_full  = make_dmatrix(df, full_es_idx)
        booster_full = train_aft(params, dtrain_full, deval_full)
        best_iter_full = booster_full.best_iteration if hasattr(booster_full, "best_iteration") else None
        print(f"  [FULL] Best iteration: {best_iter_full}")

        # Exporta com sufixo _FULL para distinguir do modelo de avaliacao
        full_outdir = outdir / "full_retrain"
        full_outdir.mkdir(parents=True, exist_ok=True)

        x_full_df = df.loc[full_fit_idx, FEATURE_COLUMNS]
        pred_full  = predict_mfe(booster_full,
                                 xgb.DMatrix(x_full_df, feature_names=FEATURE_COLUMNS),
                                 best_iter_full)

        full_export_path, full_export_report = export_aft_to_mql5(
            booster_full, FEATURE_COLUMNS, full_outdir, mfe_threshold,
            best_iter_full, x_full_df, pred_full,
        )

        if full_export_path and full_export_report.get("decision_match_pct", 0) >= 0.999:
            print(f"\n  [FULL] MODELO DE PRODUCAO EXPORTADO:")
            print(f"         {full_export_path}")
            print(f"         Arvores: {full_export_report['active_tree_count']}")
            print(f"         MFE threshold: {mfe_threshold:.3f}")
            print(f"         Validacao 1:1: max_diff={full_export_report['max_abs_diff']:.2e}")
            print(f"\n  Copie o arquivo acima para substituir o placeholder no EA.")
        else:
            print(f"  [FULL] AVISO: exportacao com problemas — {full_export_report}")

    total_time = time.time() - t0

    # ==== SUMMARY ====
    print("\n" + "=" * 70)
    print("  PIPELINE AFT CONCLUIDO")
    print(f"  Tempo total: {total_time:.1f}s ({total_time/60:.1f}min)")
    print(f"  Dataset: {dataset_path}")
    print(f"  Saidas: {outdir}")
    print("=" * 70)

    print(f"\n  MFE THRESHOLD: {mfe_threshold:.3f}")
    print(f"  C-INDEX: {c_index:.4f}")
    print(f"\n  RESULTADOS MULTI-R (test OOS):")
    print(f"  {'R Target':<10} {'Precision':<12} {'Win Rate':<12} "
          f"{'E[R]/trade':<12} {'E[R]/year':<12} {'PF':<8} {'Trades':<10} {'Trades/yr':<10}")
    print(f"  {'-'*86}")
    for r_target, metrics in sorted(multi_r_results.items()):
        r_label = f"{int(r_target)}R" if r_target == int(r_target) else f"{r_target:.1f}R"
        sel = " *" if r_target == selected_r else ""
        print(f"  {r_label:<10}{sel:<3}"
              f"{metrics['precision']:<12.4f} {metrics['win_rate']:<12.4f} "
              f"{metrics['expected_r_per_trade']:<12.4f} "
              f"{metrics['expected_r_per_year']:<12.1f} "
              f"{metrics['profit_factor']:<8.2f} "
              f"{metrics['trade_count']:<10} "
              f"{metrics['trades_per_year']:<10.0f}")

    print(f"\n  TOP 10 FEATURES (gain):")
    for i, row in fi_model.head(10).iterrows():
        print(f"    {i+1:2d}. {row['feature']:<45} {row['importance']:.1f}")

    print()


if __name__ == "__main__":
    main()
