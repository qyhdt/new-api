package controller

import (
	"errors"
	"fmt"
	"strings"
	"unicode"

	"github.com/QuantumNous/new-api/common"
	"github.com/QuantumNous/new-api/i18n"
	"github.com/QuantumNous/new-api/model"
	"github.com/gin-contrib/sessions"
	"github.com/gin-gonic/gin"
	"github.com/golang-jwt/jwt/v5"
	"golang.org/x/text/unicode/norm"
	"gorm.io/gorm"
)

func ThyseedSsoLogin(c *gin.Context) {
	if !common.ThyseedSsoEnabled {
		common.ApiErrorI18n(c, i18n.MsgThyseedSsoNotEnabled)
		return
	}

	tokenString := extractBearerToken(c.GetHeader("Authorization"))
	if tokenString == "" {
		common.ApiErrorI18n(c, i18n.MsgThyseedSsoMissingToken)
		return
	}

	username, err := parseThyseedSsoUsername(tokenString)
	if err != nil {
		common.ApiErrorI18n(c, i18n.MsgThyseedSsoInvalidToken)
		return
	}

	user, err := findOrCreateThyseedSsoUser(c, username)
	if err != nil {
		switch err {
		case errThyseedSsoUserDeleted:
			common.ApiErrorI18n(c, i18n.MsgOAuthUserDeleted)
		case errThyseedSsoRegisterDisabled:
			common.ApiErrorI18n(c, i18n.MsgUserRegisterDisabled)
		case errThyseedSsoInvalidUsername:
			common.ApiErrorI18n(c, i18n.MsgThyseedSsoInvalidUsername)
		default:
			common.ApiError(c, err)
		}
		return
	}

	if user.Status != common.UserStatusEnabled {
		common.ApiErrorI18n(c, i18n.MsgOAuthUserBanned)
		return
	}

	setupLogin(user, c)
}

var (
	errThyseedSsoUserDeleted       = errors.New("thyseed sso user deleted")
	errThyseedSsoRegisterDisabled  = errors.New("thyseed sso register disabled")
	errThyseedSsoInvalidUsername   = errors.New("thyseed sso invalid username")
)

func extractBearerToken(header string) string {
	header = strings.TrimSpace(header)
	if header == "" {
		return ""
	}
	const prefix = "Bearer "
	if len(header) < len(prefix) || !strings.EqualFold(header[:len(prefix)], prefix) {
		return ""
	}
	return strings.TrimSpace(header[len(prefix):])
}

func parseThyseedSsoUsername(tokenString string) (string, error) {
	token, err := jwt.Parse(tokenString, func(token *jwt.Token) (any, error) {
		if _, ok := token.Method.(*jwt.SigningMethodHMAC); !ok {
			return nil, fmt.Errorf("unexpected signing method: %v", token.Header["alg"])
		}
		return []byte(common.ThyseedJwtSecret), nil
	}, jwt.WithValidMethods([]string{"HS256"}))
	if err != nil || !token.Valid {
		return "", err
	}

	claims, ok := token.Claims.(jwt.MapClaims)
	if !ok {
		return "", errors.New("invalid claims")
	}
	sub, _ := claims["sub"].(string)
	return normalizeThyseedUsername(sub), nil
}

func normalizeThyseedUsername(username string) string {
	username = strings.TrimSpace(username)
	if username == "" {
		return ""
	}
	return norm.NFC.String(username)
}

func findOrCreateThyseedSsoUser(c *gin.Context, username string) (*model.User, error) {
	if username == "" || len(username) > model.UserNameMaxLength {
		return nil, errThyseedSsoInvalidUsername
	}
	for _, r := range username {
		if unicode.IsControl(r) {
			return nil, errThyseedSsoInvalidUsername
		}
	}

	user := &model.User{}
	err := model.DB.Unscoped().Where("username = ?", username).First(user).Error
	if err == nil {
		if user.DeletedAt.Valid {
			return nil, errThyseedSsoUserDeleted
		}
		return user, nil
	}
	if !errors.Is(err, gorm.ErrRecordNotFound) {
		return nil, err
	}

	if !common.ThyseedSsoAutoRegister && !common.RegisterEnabled {
		return nil, errThyseedSsoRegisterDisabled
	}

	session := sessions.Default(c)
	affCode := session.Get("aff")
	inviterId := 0
	if affCode != nil {
		inviterId, _ = model.GetUserIdByAffCode(affCode.(string))
	}

	newUser := model.User{
		Username:    username,
		DisplayName: username,
		Role:        common.ThyseedSsoDefaultRole,
		Status:      common.UserStatusEnabled,
	}
	if err := newUser.Insert(inviterId); err != nil {
		return nil, err
	}
	return &newUser, nil
}
