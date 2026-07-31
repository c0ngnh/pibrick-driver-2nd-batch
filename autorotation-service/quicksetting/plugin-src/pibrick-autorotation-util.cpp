// SPDX-FileCopyrightText: 2026 piBrick Project
// SPDX-License-Identifier: GPL-3.0-or-later
//
// See header for design notes.

#include "pibrick-autorotation-util.h"

#include <QFile>
#include <QFileInfo>
#include <QProcess>
#include <QStandardPaths>
#include <QTimer>

namespace {

// Read ~/.config/kwinoutputconfig.json and return the autoRotation value
// for the first output, or "Unknown" if the file is missing or malformed.
// Returns an empty string on hard parse errors (file does not exist, etc.)
QString readAutoRotationField(const QString &path)
{
    QFile f(path);
    if (!f.open(QIODevice::ReadOnly | QIODevice::Text)) {
        return {};
    }
    const QByteArray contents = f.readAll();
    f.close();

    // The file is JSON; we only do a substring scan because we want to
    // avoid pulling in Qt::Json as a build dependency for this single
    // file. The expected shape (see autorotation-lock.sh) is:
    //
    //   [ { "name": "outputs", "data": [
    //       { ..., "autoRotation": "InTabletMode" | "Always" | "Disabled" }
    //   ] } ]
    //
    // We pick the FIRST "autoRotation" value we encounter — there is only
    // one in practice on this device.
    const QByteArray needle = "\"autoRotation\"";
    int idx = contents.indexOf(needle);
    if (idx < 0) {
        return {};
    }
    int colon = contents.indexOf(':', idx);
    if (colon < 0) {
        return {};
    }
    // Skip whitespace and opening quote.
    int p = colon + 1;
    while (p < contents.size() && (contents[p] == ' ' || contents[p] == '\t')) {
        ++p;
    }
    if (p >= contents.size() || contents[p] != '"') {
        return {};
    }
    ++p;
    int end = contents.indexOf('"', p);
    if (end < 0) {
        return {};
    }
    return QString::fromUtf8(contents.mid(p, end - p));
}

// ~350 ms after running the helper, the file is up-to-date enough for us
// to safely re-read. Anything shorter risks reading the pre-write state.
constexpr int kResyncDelayMs = 350;

} // namespace

PibrickAutorotationUtil::PibrickAutorotationUtil(QObject *parent)
    : QObject(parent)
{
}

bool PibrickAutorotationUtil::autoRotationEnabled() const
{
    if (!m_cacheValid) {
        m_cachedEnabled = readAutoRotationFromConfig();
        m_cacheValid = true;
    }
    return m_cachedEnabled;
}

void PibrickAutorotationUtil::setAutoRotationEnabled(bool enabled)
{
    const bool current = autoRotationEnabled();
    if (enabled == current) {
        // No-op: don't shell out if nothing will change.
        return;
    }

    // Run the helper detached. We deliberately do NOT block the QML
    // engine — the helper is fire-and-forget; the resync timer below
    // re-reads the config and emits the property-change signal.
    const QStringList args { enabled ? QStringLiteral("auto")
                                     : QStringLiteral("lock-current") };
    QProcess::startDetached(m_helperPath, args);

    // Optimistically flip the cache so the UI updates immediately. The
    // resync timer corrects the value if the helper exited non-zero.
    m_cachedEnabled = enabled;
    m_cacheValid = true;
    Q_EMIT autoRotationEnabledChanged();

    QTimer::singleShot(kResyncDelayMs, this, [this]() {
        const bool oldCache = m_cachedEnabled;
        const bool oldValid = m_cacheValid;
        m_cacheValid = false;     // force re-read
        const bool fresh = autoRotationEnabled();
        if (fresh != oldCache || oldValid != m_cacheValid) {
            Q_EMIT autoRotationEnabledChanged();
        }
    });
}

void PibrickAutorotationUtil::lockCurrent()
{
    if (m_cachedEnabled) {
        setAutoRotationEnabled(false);
    }
}

void PibrickAutorotationUtil::enableAuto()
{
    if (!m_cachedEnabled) {
        setAutoRotationEnabled(true);
    }
}

void PibrickAutorotationUtil::refreshFromConfig()
{
    const bool wasEnabled = autoRotationEnabled();
    m_cacheValid = false;
    const bool nowEnabled = autoRotationEnabled();
    if (wasEnabled != nowEnabled) {
        Q_EMIT autoRotationEnabledChanged();
    }
}

bool PibrickAutorotationUtil::readAutoRotationFromConfig() const
{
    if (m_kwinConfigPath.isEmpty()) {
        // Resolve lazily so that HOME-changing tests / cross-user setups
        // get a fresh path on first use.
        const QString home = qEnvironmentVariable("HOME");
        if (home.isEmpty()) {
            return true; // best-effort: assume enabled when we cannot tell
        }
        m_kwinConfigPath = home + QStringLiteral("/.config/kwinoutputconfig.json");
    }

    const QString value = readAutoRotationField(m_kwinConfigPath);
    if (value.isEmpty()) {
        // Missing or unreadable: be conservative and report "enabled" so
        // the tile doesn't spuriously claim the screen is locked.
        return true;
    }
    return value != QLatin1String("Disabled");
}

#include "moc_pibrick-autorotation-util.cpp"
