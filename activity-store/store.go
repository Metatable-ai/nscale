package activitystore

import "time"

type Store interface {
LastActivity(service string) (time.Time, bool, error)
SetActivity(service string, at time.Time) error
}

const (
DefaultNamespace = "scale-to-zero"
ActivityPrefix   = "activity/"
)
